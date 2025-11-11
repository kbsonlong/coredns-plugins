package azroute

import (
    context "context"
    "encoding/json"
    "io"
    "log"
    "net"
    "net/http"
    "os"
    "strings"
    "sync"
    "time"

    "github.com/coredns/coredns/plugin"
    lru "github.com/hashicorp/golang-lru"
    "github.com/miekg/dns"
    "github.com/yl2chen/cidranger"
)

type AzMapEntry struct {
    Subnet string `json:"sub"`
    AZ     string `json:"az"`
}

type AzRoute struct {
    Next      plugin.Handler
    AzMap     []AzMapEntry
    AzMapLock sync.RWMutex
    ApiUrl    string
    AzMapFile string
    IpAzMap   map[string]string // IP -> AZ

    Ranger  cidranger.Ranger // 新增：高效网段查找结构
    AzCache *lru.Cache       // 新增：LRU缓存
    LruSize int              // LRU缓存最大容量
}

type responseCaptureWriter struct {
	dns.ResponseWriter
	Msg *dns.Msg
}

func (r *responseCaptureWriter) WriteMsg(res *dns.Msg) error {
	r.Msg = res
	return nil // 不直接写出，由 azroute 处理
}

func (a *AzRoute) ServeDNS(ctx context.Context, w dns.ResponseWriter, r *dns.Msg) (int, error) {
	// 捕获下游（如 hosts）插件的响应
	rw := &responseCaptureWriter{ResponseWriter: w}
	code, err := plugin.NextOrFailure(a.Name(), a.Next, ctx, rw, r)
	if err != nil || rw.Msg == nil || len(rw.Msg.Answer) == 0 {
		return code, err
	}
	// 仅有一个地址时没有必要判断可用区逻辑直接返回
	if len(rw.Msg.Answer) == 1 {
		w.WriteMsg(rw.Msg)
		return dns.RcodeSuccess, nil
	}

	clientIP := getClientIP(w.RemoteAddr().String())
	az := a.findAZ(clientIP)
	log.Printf("[azroute] clientIP=%s, matched AZ=%s", clientIP, az)

	var answers []dns.RR
	var allAnswers []dns.RR
	var allIPs []string
	for _, rr := range rw.Msg.Answer {
		switch v := rr.(type) {
		case *dns.A:
			allAnswers = append(allAnswers, rr)
			allIPs = append(allIPs, v.A.String())
			if az != "" && a.findAZ(v.A.String()) == az {
				answers = append(answers, rr)
			}
		case *dns.AAAA:
			allAnswers = append(allAnswers, rr)
			allIPs = append(allIPs, v.AAAA.String())
			if az != "" && a.findAZ(v.AAAA.String()) == az {
				answers = append(answers, rr)
			}
		default:
			// 其他类型直接透传
		}
	}
	log.Printf("[azroute] hosts returned IPs: %v", allIPs)
	// 如果没有同 AZ 的，返回全部 A/AAAA
	if len(answers) == 0 || len(allIPs) == 1 {
		answers = allAnswers
	}
	var retIPs []string
	for _, rr := range answers {
		switch v := rr.(type) {
		case *dns.A:
			retIPs = append(retIPs, v.A.String())
		case *dns.AAAA:
			retIPs = append(retIPs, v.AAAA.String())
		}
	}
	log.Printf("[azroute] final returned IPs: %v", retIPs)
	if len(answers) == 0 {
		return code, err
	}

	m := new(dns.Msg)
	m.SetReply(r)
	m.Answer = answers
	w.WriteMsg(m)
	return dns.RcodeSuccess, nil
}

func (a *AzRoute) findAZ(ip string) string {
	if a.AzCache != nil {
		if v, ok := a.AzCache.Get(ip); ok {
			return v.(string)
		}
	}
	a.AzMapLock.RLock()
	defer a.AzMapLock.RUnlock()
	if a.Ranger == nil {
		return ""
	}
	ipAddr := net.ParseIP(ip)
	entries, err := a.Ranger.ContainingNetworks(ipAddr)
	if err != nil || len(entries) == 0 {
		if a.AzCache != nil {
			a.AzCache.Add(ip, "")
		}
		return ""
	}
	if azEntry, ok := entries[0].(*azRangerEntry); ok {
		if a.AzCache != nil {
			a.AzCache.Add(ip, azEntry.AZ())
		}
		return azEntry.AZ()
	}
	if a.AzCache != nil {
		a.AzCache.Add(ip, "")
	}
	return ""
}

func (a *AzRoute) Name() string { return "azroute" }

func (a *AzRoute) InitAndUpdateAzMap() {
    // 初始加载
    combined := a.combineAzMaps()
    if len(combined) > 0 {
        a.setAzMap(combined)
    }
    size := a.LruSize
    if size <= 0 {
        size = 1024 // 默认值
    }
    cache, err := lru.New(size)
	if err != nil {
		log.Printf("[azroute] LRU缓存初始化失败: %v", err)
	} else {
		a.AzCache = cache
	}
    go func() {
        for {
            time.Sleep(60 * time.Second)
            combined := a.combineAzMaps()
            if len(combined) > 0 {
                a.setAzMap(combined)
            }
        }
    }()
}

// setAzMap 将映射设置到插件并重建索引及缓存
func (a *AzRoute) setAzMap(azmap []AzMapEntry) {
    a.AzMapLock.Lock()
    a.AzMap = azmap
    // 构建Ranger
    ranger := cidranger.NewPCTrieRanger()
    for _, entry := range azmap {
        _, network, err := net.ParseCIDR(entry.Subnet)
        if err == nil {
            ranger.Insert(&azRangerEntry{network: *network, az: entry.AZ})
        }
    }
    a.Ranger = ranger
    if a.AzCache != nil {
        a.AzCache.Purge() // 热加载时清空缓存
    }
    a.AzMapLock.Unlock()
}

// combineAzMaps 从 API 与文件中加载并合并映射，文件条目优先生效
func (a *AzRoute) combineAzMaps() []AzMapEntry {
    combined := make(map[string]AzMapEntry)
    // 先加载 API
    if a.ApiUrl != "" {
        if apiEntries, err := a.fetchAzMapFromAPI(); err != nil {
            log.Printf("[azroute] fetch API error: %v", err)
        } else {
            for _, e := range apiEntries {
                combined[e.Subnet] = e
            }
        }
    }
    // 再加载文件，覆盖同 subnet 的条目
    if a.AzMapFile != "" {
        if fileEntries, err := a.fetchAzMapFromFile(); err != nil {
            log.Printf("[azroute] read azmap_file error: %v", err)
        } else {
            for _, e := range fileEntries {
                combined[e.Subnet] = e
            }
        }
    }
    // 转回 slice
    res := make([]AzMapEntry, 0, len(combined))
    for _, v := range combined {
        res = append(res, v)
    }
    if len(res) > 0 {
        log.Printf("[azroute] 已合并AZ映射，来源: API=%t, File=%t, 总数=%d", a.ApiUrl != "", a.AzMapFile != "", len(res))
    }
    return res
}

// fetchAzMapFromAPI 拉取 API 映射
func (a *AzRoute) fetchAzMapFromAPI() ([]AzMapEntry, error) {
    resp, err := http.Get(a.ApiUrl)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    body, err := io.ReadAll(resp.Body)
    if err != nil {
        return nil, err
    }
    var azmap []AzMapEntry
    if err := json.Unmarshal(body, &azmap); err != nil {
        return nil, err
    }
    return azmap, nil
}

// fetchAzMapFromFile 从本地文件读取映射，文件内容为 JSON 数组 [{"sub":"CIDR","az":"az-x"}, ...]
func (a *AzRoute) fetchAzMapFromFile() ([]AzMapEntry, error) {
    data, err := os.ReadFile(a.AzMapFile)
    if err != nil {
        return nil, err
    }
    var azmap []AzMapEntry
    if err := json.Unmarshal(data, &azmap); err != nil {
        return nil, err
    }
    return azmap, nil
}

// azRangerEntry实现cidranger.RangerEntry接口

type azRangerEntry struct {
	network net.IPNet
	az      string
}

func (e *azRangerEntry) Network() net.IPNet {
	return e.network
}

func (e *azRangerEntry) AZ() string {
    return e.az
}

// getClientIP 提取客户端IP
func getClientIP(addr string) string {
	if strings.Contains(addr, "[") { // IPv6
		addr = strings.Split(addr, "]:")[0]
		addr = strings.TrimPrefix(addr, "[")
	} else {
		addr = strings.Split(addr, ":")[0]
	}
	return addr
}
