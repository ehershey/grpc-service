# gRPC & gRPC-Web Services on Fly.io

> Run gRPC & gRPC-Web services close to users with [Fly](https://fly.io/).

## Overview

<!---- cut here --->

This application demonstrates how to run a gRPC service on Fly.io. Fly runs tiny virtual machines at edge datacenters close to your users.

gRPC is designed for fast, low overhead services with client and server code generation tools for many languages and VMs.

gRPC servers run their own HTTP/2-based protocol, so they offer excellent performance benefits. This will not work out of the box with most hosting platforms. In fact, you can't even call the service directly from a web browser. In this example, we'll consume the gRPC service with a special web adapter. This allows you to create the client stubs and use them in browser-based JavaScript.

This example uses the [gRPC](https://grpc.io) libraries for the main gRPC service and [grpcwebproxy](https://github.com/improbable-eng/grpc-web/tree/master/go/grpcwebproxy) for browser support.
## What we'll deploy

Since this is an example, we'll write a quick gRPC service definition in [`hello.proto`](https://github.com/fly-examples/grpc-service/blob/master/hello.proto) that has the following methods:

```protobuf
service MainService {
  rpc Hello(Empty) returns (Greeting);
  rpc Clock(Empty) returns (stream Time);
}
```

## Deploying the gRPC service to Fly

- Install [flyctl](https://fly.io/docs/getting-started/installing-flyctl/)
- Login to Fly using `fly auth login`
- Create and deploy the app with `fly launch`
## Using the gRPC service

With gRPC, you'll usually use the generated client libraries in the language of your choice.

To make sure our service is working, we'll use the [`grpcurl`](https://github.com/fullstorydev/grpcurl) tool:

```shell
grpcurl -proto hello.proto grpc-test.fly.dev:443 MainService/Hello
```

You can also test streaming by calling the `Clock` method. It sends a timestamp every second:

```shell
grpcurl -proto hello.proto grpc-test.fly.dev:443 MainService/Clock
```
## What's Happening Inside

The gRPC servers that we're running have one special feature that makes them difficult to deploy on many systems – they use the relatively new HTTP/2 protocol with a special feature called HTTP Trailers. Most HTTP/2 load balancers will terminate the HTTP/2 connection at the load balancer, and then make a more compliant HTTP/1.1 connection on the backend to the application server. This won't work with gRPC, so we need to drop down to using lower-level TCP load balancing.

Luckily, Fly supports TCP balancing just fine, with the following configuration in your `fly.toml`:

```toml
[[services]]
  internal_port = 54321
  protocol = "tcp"

  [[services.ports]]
    handlers = ["tls"]
    port = "443"

  [services.ports.tls_options]
    alpn = ["h2"]

```

We also need to tell Fly to have only a TLS (no HTTP) listener on 443 – this takes care of encryption and allows Fly to terminate TLS with the default, managed, or the configured certificates. If we wanted to, we could also handle TLS entirely within the application itself, by removing all Fly listeners and activating the [TCP Passthrough](https://fly.io/docs/services/#tcp-pass-through).

Once the TCP request reaches your gRPC application, the server will then take over and provide threading / event loop / goroutine management, depending on your chosen language, along with serialization and deserialization.

## Using the Web Proxy

Because the gRPC services uses HTTP/2, you can't make requests to it from inside a browser — there are currently no browser APIs that allow direct and full control of a HTTP/2 connection. To enable use inside a browser, there's a [gRPC-Web](https://grpc.io/docs/languages/web/) specification that converts a normal HTTP/1.1 request to and from the gRPC HTTP/2 format. Multiple proxy servers that implement the spec are available, like [Envoy](https://grpc.io/docs/languages/web/basics/#configure-the-envoy-proxy) and [grpcwebproxy](https://github.com/improbable-eng/grpc-web/tree/master/go/grpcwebproxy) (which we've deployed here). We've generated JS code for our gRPC definition using the instructions [on the official gRPC-Web example page](https://github.com/grpc/grpc-web/tree/master/net/grpc/gateway/examples/helloworld#generate-protobuf-messages-and-client-service-stub), so let's see how to use it.

 In the `web-proxy` folder, the [`client.js`](https://github.com/fly-examples/grpc-service/blob/master/web-proxy/client.js) file calls the two methods of our service and writes the output into `console.log`. You can change the following [line](https://github.com/fly-examples/grpc-service/blob/master/web-proxy/client.js#L4):

```js
 var client = new MainServiceClient('https://grpc-web-proxy-test.fly.dev:443');
```

to update it with your web proxy app's hostname and then run:

```shell
npm install
npx webpack client.js
open index.html
```

This will re-compile the client and open up your browser, where the method repsonses are being printed into the console.

You'll notice that the clock stops streaming after exactly 10 seconds – this is based on a [flag](https://github.com/improbable-eng/grpc-web/blob/b16a11b6e855a48b6bc6e369a85f3d46fcfe1a77/go/grpcwebproxy/main.go#L45) in the proxy configuration that you'll want to set if your services have longer-running methods. For example, you can set them to 1 hour by adding `--server_http_max_write_timeout=3600` and `--server_http_max_read_timeout=3600` to the `ENTRYPOINT` command in [`web-proxy/Dockerfile`](https://github.com/fly-examples/grpc-service/blob/master/web-proxy/Dockerfile#L40).

## How Does Fly Fit Into This?

While gRPC works really well when communicating between servers on the same rack or same datacenter, the principles it uses apply equally well to clients on websites or mobile devices. The HTTP/2 communication channel remains open as much as possible to provide a low-latency and low-energy way to speak to your server, and the underlying [Protocol Buffers](https://developers.google.com/protocol-buffers) serialization/de-serialization system is very low-overhead, so it's great for cellular or metered-bandwidth connections.

Running your backend services on Fly lets you put your services really close to every user in your global client base. If your data is in a central location, your services can use the local Redis cache that Fly provides at each edge location to cache data, and broadcast changes or invalidations via the [global Redis command broadcast](https://fly.io/docs/redis/#managing-redis-data-globally). There are also data solutions from other cloud providers like [DynamoDB Global Tables](https://aws.amazon.com/dynamodb/global-tables/) (NoSQL), [Aurora Multi-Master](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html) (SQL) or [Google Cloud Spanner](https://cloud.google.com/spanner) (SQL) that can help spread your data across the world and closer to your application servers.

The reduced latency from having your servers close to your clients is especially useful in gRPC where you want all your calls to finish as quickly as possible. If your clients are mobile applications, they'll benefit even more from the latency reduction when they're running on cellular networks, where bandwidth is low and re-connections are common.

## Testing gRPC performance with `ghz`

Because gRPC applications use a special wire protocol, we can't use `cURL`, `wget` or `siege` like we would on normal servers. Instead, there are special gRPC-aware tools like [ghz](https://ghz.sh) that work great. After you enable the Fly regions you'd like to run your service in and set the container CPU & memory configuration to the size you need, you can use `ghz` to test your service:

```
ghz grpc-test.fly.dev:443 --call=MainService/Hello --proto=hello.proto
```

Keep in mind that this test will run against your closest enabled Fly region, which may or may not be the region that your users will use. gRPC testing also works a little different, because a single HTTP/2 connection is re-used across many requests. Testing against dummy methods that don't do much is really just a test of single connection bandwidth. The best way to make sure your service is running great would be to enable the instrumentation provided in your client and service libraries and exercise your service in a real-world scenario.
