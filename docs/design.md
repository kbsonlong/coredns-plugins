# azroute 插件设计文档

## 1. 设计目标
- 实现基于可用区（AZ）的 DNS 解析就近调度。
- 用户只需维护 hosts 文件，AZ 信息自动感知。
- 支持 API 动态热加载网段-AZ 映射。
- 支持 IPv4/IPv6，A/AAAA 记录。

## 2. 架构与流程

```mermaid
graph TD
    Client-->|DNS Query|CoreDNS
    CoreDNS-->|hosts插件|hosts
    hosts-->|A/AAAA记录|azroute
    azroute-->|API拉取AZ映射|API
    azroute-->|优选IP|Client
```

- hosts 插件负责域名到 IP 的静态解析。
- azroute 插件负责根据客户端 IP 匹配 AZ，并对 hosts 返回的 IP 进行 AZ 优选。
- azroute 插件定时从 API 拉取网段-AZ 映射，支持热加载。

## 3. 关键流程
1. CoreDNS 收到 DNS 查询。
2. hosts 插件返回所有匹配的 IP。
3. azroute 插件根据客户端 IP 匹配 AZ。
4. azroute 插件优先返回同 AZ 的 IP，否则返回全部。
5. 若 API 不可用，使用上次缓存。

## 4. 扩展点
- 支持多 API 源、缓存优化。
- 支持自定义调度策略（如权重、健康检查等）。
- 支持更多类型的 DNS 记录。

### 4.1 基于文件的AZ映射（新增）
- 新增 azmap_file 配置项，支持从本地文件加载网段-AZ映射；文件格式与 API 相同（JSON 数组）。
- 当同时配置 azmap_api 与 azmap_file 时，合并两者：文件条目覆盖相同 subnet 的 API 条目，其余保持并集。
- 插件每 60s 周期性热加载两类来源，重建 CIDR 索引（cidranger）并清理 LRU 缓存。

## 5. 主要结构
- AzRoute：插件主结构体，维护 AZ 映射、API 地址等。
- findAZ：根据 IP 匹配 AZ。
- ServeDNS：主处理逻辑，捕获 hosts 返回的 IP 并优选。
- setAzMap：统一设置映射并重建索引与缓存。
- fetchAzMapFromAPI：拉取 API 映射。
- fetchAzMapFromFile：读取文件映射。
- combineAzMaps：合并 API 与文件来源的映射。

## 6. 典型时序图
```mermaid
sequenceDiagram
    participant Client
    participant CoreDNS
    participant hosts
    participant azroute
    participant API
    Client->>CoreDNS: DNS Query
    CoreDNS->>hosts: 查询域名
    hosts-->>CoreDNS: 返回A/AAAA记录
    CoreDNS->>azroute: 交给azroute处理
    azroute->>API: 拉取AZ映射
    API-->>azroute: 返回网段-AZ
    azroute-->>CoreDNS: 优选IP
    CoreDNS-->>Client: 返回结果
```