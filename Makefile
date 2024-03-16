test:
	timeout 5 grpcurl -proto hello.proto $$(fly status -j | jq -r .Hostname):443 MainService/Clock || true
	timeout 5 grpcurl -proto hello.proto $$(fly status -j | jq -r .Hostname):443 MainService/Hello

.PHONY: test deploy

deploy:
	flyctl deploy && cd web-proxy && flyctl deploy
