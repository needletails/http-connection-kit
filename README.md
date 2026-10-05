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

Policies live on `Configuration`, not on each request. Defaults follow redirects (limit 8), decompress `gzip` and `deflate`, keep an empty `CookieJar`, and set no authenticator and no progress callback.

## Bodies, forms, and streams

`HTTPBody` is a pull `AsyncSequence` of `Data`. Upload accepts any `Sendable` `AsyncSequence` of `Data`. Download and `MultipartForm.stream()` return `HTTPBody`, so the producer waits until the caller takes the next chunk.

```swift
let body = try HTTPBody.octets(0..<UInt8.max, chunkSize: 64)
var headers = HTTPFields()
headers[.contentType] = "application/octet-stream"
let posted = try await client.request(method: .post, url: url, headers: headers, body: body)

var form = try MultipartForm()
form.append(try .field(name: "message", value: "hello"))
form.append(try .file(name: "upload", filename: "a.bin", url: fileURL))
headers[.contentType] = form.contentType
_ = try await client.request(method: .post, url: url, headers: headers, body: form.stream())

let streamed = try await client.requestStream(method: .get, url: url)
for try await chunk in streamed.body {
    handle(chunk)
}
let trailers = await streamed.trailers()
```

A form or file with a known byte count sets `Content-Length`. An unknown stream omits it. HTTP/1 then uses chunked transfer. Dropping a streamed body closes that request. HTTP/2 and HTTP/3 keep the pooled connection.

`MultipartResponse` reads a `multipart/*` body one part at a time.

## Redirects, compression, continue, and range

`301`, `302`, and `303` become `GET` and drop the body. `307` and `308` repeat the method when the body is replayable. A one-shot body fails with `HTTPConnectionError.unreplayableBody`. `Authorization` is removed when the host changes. The `Cookie` header is built again for the new URL.

The client sends `Accept-Encoding: deflate, gzip` unless the request already has that field. Inflated `gzip` and `deflate` bodies are what the caller sees, including streamed chunks. Brotli stays compressed. A ratio bomb fails with `HTTPConnectionError.decompressionLimit`.

If the request sets `Expect: 100-continue`, the client writes the head and waits up to one second before pulling the upload. A final status skips the body.

`resumeDownload(from:to:)` sends `Range` at the current file size and `If-Range` with the stored validator. A matching `206` is appended. `200`, or a range that starts elsewhere, replaces the local file.

## Progress, authentication, and cookies

`configuration.onProgress` receives `HTTPProgress` after each upload or download chunk, with an expected total when `Content-Length` or `Content-Range` provides one.

Every `401` and `407` exposes `HTTPChallenge` values. An optional authenticator retries once with Basic, Bearer, or Digest (RFC 7616, SHA-256 preferred). `qop=auth` is the default. A Digest `stale=true` reply allows one further retry. `407` sets `Proxy-Authorization`.

`CookieJar` stores `Set-Cookie` using RFC 6265 domain, path, `Secure`, expiry, `SameSite`, prefix, and size rules. Two clients can share one jar. `PublicSuffixList` is replaceable; the package ships a snapshot.

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
