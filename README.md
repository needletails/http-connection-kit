# HTTPConnectionKit

[![Swift](https://img.shields.io/badge/Swift-6.4-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-blue.svg)](https://swift.org)

An HTTP client for HTTP/1, HTTP/2, and HTTP/3. `HTTPConnection` is an actor. Create one instance for a TLS policy, send requests on it, and call `shutdown()` when it is finished.

The preferred version is a cap. The client offers every protocol at or below that cap and uses the one the handshake selects. A `505` response is the server's answer and does not cause another attempt on a lower protocol.

## Requirements

- Swift 6.4
- macOS or Linux
- Apple OS 26 or later for HTTP/3

On Linux the client opens TCP with SwiftNIO. An HTTP/3 cap there uses the protocol negotiated on TCP.

## Installation

Add the package in `Package.swift` and depend on the `HTTPConnectionKit` product.

```swift
dependencies: [
    .package(url: "https://github.com/needletails/http-connection-kit.git", branch: "main"),
],
targets: [
    .target(
        name: "App",
        dependencies: [
            .product(name: "HTTPConnectionKit", package: "http-connection-kit"),
        ]
    ),
]
```

## Usage

```swift
import HTTPConnectionKit

let client = HTTPConnection(preferred: .http3)
let response = try await client.request(
    method: .get,
    url: URL(string: "https://example.com/")!,
    headers: [:],
    body: nil
)
print(response.head.status.code)
await client.shutdown()
```

`request` accepts GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS, TRACE, QUERY, and any other method token. CONNECT is rejected with `HTTPConnectionError.unimplemented` because it opens a tunnel.

```swift
var configuration = HTTPConnection.Configuration()
configuration.tls.minimumVersion = .tlsv13
configuration.tls.certificateVerification = .fullVerification
configuration.channel.connectTimeout = .seconds(10)

let client = HTTPConnection(preferred: .http2, configuration: configuration)
```

Timeouts are `HTTPConnection.Configuration.Interval` values, in nanoseconds. Certificate checking is `.fullVerification`, `.noHostnameVerification`, or `.none`.

## Protocol selection

| URL | Cap | Connection |
| --- | --- | --- |
| `http://` | any | HTTP/1 on cleartext TCP. The cap does not start a QUIC handshake. |
| `https://` | `.http1_0` or `.http1_1` | HTTP/1 on TLS. |
| `https://` | `.http2` | TLS offers `h2` and `http/1.1`. The selected protocol is reused. |
| `https://` | `.http3` | QUIC runs beside the TCP handshake. HTTP/3 is used when QUIC connects. Otherwise the client uses the TCP protocol and keeps that choice for the origin. |

HTTP/2 and HTTP/3 connections stay open for later requests. HTTP/1 closes with the response. Canceling a task closes the channel that request owns.

## Tests

From the package directory:

```sh
swift test
```

The suite starts local HTTP/1, HTTP/2, and HTTP/3 servers, and it also requests `https://example.com` and `https://cloudflare.com/cdn-cgi/trace`. Those public tests need outbound TCP port 443. The local HTTP/3 tests run on Apple OS 26 and later.

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs `swift test` on Swift 6.4.0 for Ubuntu 24.04 and macOS 26. The workflow runs on pushes to `main`, on pull requests, and when started manually.
