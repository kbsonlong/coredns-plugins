package azroute

import (
	"fmt"

	"github.com/coredns/caddy"
	"github.com/coredns/coredns/core/dnsserver"
	"github.com/coredns/coredns/plugin"
	clog "github.com/coredns/coredns/plugin/pkg/log"
)

func init() { plugin.Register("azroute", setup) }

func setup(c *caddy.Controller) error {
    clog.Info("[azroute] setup called")
    azroute := &AzRoute{}

    for c.Next() {
        for c.NextBlock() {
            switch c.Val() {
            case "azmap_api":
                if !c.NextArg() {
                    return c.ArgErr()
                }
                azroute.ApiUrl = c.Val()
            case "azmap_file":
                if !c.NextArg() {
                    return c.ArgErr()
                }
                azroute.AzMapFile = c.Val()
            case "lru_size":
                if !c.NextArg() {
                    return c.ArgErr()
                }
                var size int
                _, err := fmt.Sscanf(c.Val(), "%d", &size)
                if err != nil || size <= 0 {
                    return c.Errf("invalid lru_size value: %s", c.Val())
                }
                azroute.LruSize = size
            }
        }
    }

    azroute.InitAndUpdateAzMap()
    dnsserver.GetConfig(c).AddPlugin(func(next plugin.Handler) plugin.Handler {
        azroute.Next = next
        return azroute
    })
    return nil
}
