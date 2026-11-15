//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===

// Adapted from hummingbird-examples/multipart-form (RequestDecoder, FormDataCoding, File).

import Foundation
import Hummingbird
import MultipartKit
import NIOCore

public struct SynapseContext: RequestContext {
    public var coreContext: CoreRequestContextStorage

    public init(source: Source) { self.coreContext = .init(source: source) }

    // shortcut: multipart bodies are collected in memory up to 1 GiB; stream to disk if users upload huge files (path jobs avoid this).
    public var maxUploadSize: Int { 1 << 30 }

    public var requestDecoder: SynapseRequestDecoder { SynapseRequestDecoder() }
}

/// JSON for `/v1/jobs`, multipart for everything else.
public struct SynapseRequestDecoder: RequestDecoder {
    public func decode<T: Decodable>(_ type: T.Type, from request: Request, context: some RequestContext) async throws -> T {
        do {
            let ct = request.headers[.contentType] ?? ""
            if ct.lowercased().hasPrefix("application/json") {
                return try await JSONDecoder().decode(type, from: request, context: context)
            }
            return try await FormDataDecoder().decode(type, from: request, context: context)
        } catch let e as HTTPError {
            throw e
        } catch {
            throw HTTPError(.badRequest, message: "Invalid request body: \(error)")
        }
    }
}

extension FormDataDecoder {
    func decode<T: Decodable>(_ type: T.Type, from request: Request, context: some RequestContext) async throws -> T {
        guard let contentType = request.headers[.contentType],
              let mediaType = MediaType(from: contentType),
              let parameter = mediaType.parameter,
              parameter.name == "boundary"
        else { throw HTTPError(.unsupportedMediaType) }
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        return try self.decode(T.self, from: buffer, boundary: parameter.value)
    }
}

/// A file part. Bazarr (python-requests) sends parts without a content-type, so that and the filename are lenient.
public struct File: MultipartPartConvertible, Decodable, Sendable {
    public let data: ByteBuffer
    public let filename: String
    public let contentType: String?

    public var multipart: MultipartPart? { nil }

    public init?(multipart: MultipartPart) {
        data = multipart.body
        contentType = multipart.headers["content-type"].first
        let disposition = multipart.headers["content-disposition"].first ?? ""
        filename = Self.filename(in: disposition) ?? "upload"
    }

    private static func filename(in disposition: String) -> String? {
        guard let r = disposition.range(of: "filename=\"") else { return nil }
        let rest = disposition[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let name = String(rest[..<end])
        return name.isEmpty ? nil : name
    }
}
