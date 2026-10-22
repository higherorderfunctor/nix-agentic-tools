// Command cpa-gate is Caddy with its standard modules and the cpa_gate
// handler: the same main as Caddy's own cmd/caddy, plus one import, which is
// what xcaddy would generate.
package main

import (
	_ "time/tzdata"

	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	_ "cpagate/gate"
	_ "github.com/caddyserver/caddy/v2/modules/standard"
)

func main() {
	caddycmd.Main()
}
