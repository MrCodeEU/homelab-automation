module github.com/MrCodeEU/homelab-automation/tools

go 1.25.2

require (
	github.com/breml/go-uptime-kuma-client v0.4.2
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/google/uuid v1.6.0 // indirect
	github.com/maldikhan/go.socket.io v0.1.1 // indirect
	github.com/maniartech/signals v1.3.1 // indirect
	golang.org/x/net v0.58.0 // indirect
	golang.org/x/sync v0.22.0 // indirect
)

replace github.com/breml/go-uptime-kuma-client => ./thirdparty/go-uptime-kuma-client
