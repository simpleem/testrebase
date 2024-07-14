//
//  CallTokenProvider.swift
//  SeaTalkCall
//
//  Created by Wang Jinghan on 7/22/20.
//

import Foundation
import SeaCall
import SeaReactive
import SeaTalkTCP
import SeaTalkProtocol
import SeaTalkCallMetrics
import SeaCache
import SeaTalkConfigProtocol
import SeaTalkCore


protocol CallTokenProviderProtocol: TokenProviderProtocol {
    var didSendRequestSignal: Signal<RequestID, Never> { get }
    
    func refreshAuthTokenIfNeeded() -> SignalProducer<NoValue, Error>
    func fetchPeerID() -> SignalProducer<PeerID, Error>
    func setDelegate(_ delegate: CallTokenProviderDelegate)
}

protocol CallTokenProviderDelegate: AnyObject {
    func provider(_ provider: CallTokenProviderProtocol, didEndRequest requestID: RequestID, begin: Date, error: Error?)
}

class CallTokenProvider: CallTokenProviderProtocol {
    
    private enum CacheKeys {
        static let tokenCache = "token-cache"
    }
    
    private struct CachedToken: Codable {
        let token: String
        let peerID: String
        let expiryDate: Int64
    }
    
    private let tcpProvider: TCPProviderProtocol
    private let cache: CacheSyncContainer
    private var memCache: TCPRequest.UniversalCallApplyToken.Reply?
    
    let didSendRequestSignal: Signal<RequestID, Never>
    private let didSendRequestObserver: Signal<RequestID, Never>.Observer
    
    weak var delegate: CallTokenProviderDelegate?
    
    init(tcpProvider: TCPProviderProtocol, moduleDirectory: ModuleDirectory) {
        self.tcpProvider = tcpProvider
        (didSendRequestSignal, didSendRequestObserver) = Signal.pipe()
        
        let cacheDirectory = NSString.path(withComponents: [moduleDirectory.document, "CallTokenCache"])
        let diskConfig = CacheConfig.OnDisk(absolutePath: cacheDirectory, expiry: .never)
        self.cache = HybridCache(inMemoryConfig: .default, onDiskConfig: diskConfig)
    }
    
    deinit {
        didSendRequestObserver.sendCompleted()
    }
    
    func refreshAuthTokenIfNeeded() -> SignalProducer<NoValue, Error> {
        Logger.info()
        return fetchReply(forceRefresh: false).map { reply in
            return .none
        }
    }
    
    func fetchAuthToken(forceRefresh: Bool) -> SignalProducer<SeaCall.AuthToken, Error> {
        return fetchReply(forceRefresh: forceRefresh)
            .flatMapLatest { (reply) -> SignalProducer<SeaCall.AuthToken, Error> in
                return .value(reply.token)
            }
    }
    
    func fetchPeerID() -> SignalProducer<PeerID, Error> {
        return fetchReply(forceRefresh: false)
            .flatMapLatest { (reply) -> SignalProducer<PeerID, Error> in
                return .value(reply.peerID)
            }
    }
    
    func setDelegate(_ delegate: CallTokenProviderDelegate) {
        self.delegate = delegate
    }
    
    private func fetchReply(forceRefresh: Bool) -> SignalProducer<TCPRequest.UniversalCallApplyToken.Reply, Error> {
//        if !forceRefresh, let cached = fetchCachedReply() {
//            let currentDate = Date()
//            if TimeInterval(cached.expiryDate) > currentDate.timeIntervalSince1970 {
//                Logger.info("Fetched token from cache")
//                return .value(cached)
//            }
//            Logger.info("Token expired")
//            clearTokenCacheIfHad()
//        }
        
        let request = TCPRequest.UniversalCallApplyToken()
        let param = TCPRequest.Empty()
        let requestID = tcpProvider.generateRequestID()
        
        didSendRequestObserver.send(value: requestID)
        
        let begin = Date()
        return tcpProvider
            .send(request: request, param: param, requestID: requestID)
            .retry(upTo: 3)
            .on(failed: { [weak self] error in
                guard let self = self else { return }
                self.delegate?.provider(self, didEndRequest: requestID, begin: begin, error: error)
            })
            .on(value: { [weak self] reply in
                guard let self = self else { return }
                self.saveReplyToCache(reply)
                self.delegate?.provider(self, didEndRequest: requestID, begin: begin, error: nil)
            })
    }
    
    private func saveReplyToCache(_ reply: TCPRequest.UniversalCallApplyToken.Reply) {
        memCache = reply
        
        do {
            let data = CachedToken(token: reply.token, peerID: reply.peerID, expiryDate: reply.expiryDate)
            try cache.write(to: CacheKeys.tokenCache, data: data)
        } catch {
            Logger.error("Error writing token cache \(error)")
        }
    }
    
    private func fetchCachedReply() -> TCPRequest.UniversalCallApplyToken.Reply? {
        if let memCache = memCache {
            return memCache
        }
        if let cached = cache.loadIfExists(from: CacheKeys.tokenCache, ofType: CachedToken.self) {
            let tcpReply = TCPRequest.UniversalCallApplyToken.Reply(
                token: cached.token,
                peerID: cached.peerID,
                expiryDate: cached.expiryDate
            )
            memCache = tcpReply
            return tcpReply
        }
        return nil
    }
    
    private func clearTokenCacheIfHad() {
        memCache = nil
        
        do {
            try cache.removeData(for: CacheKeys.tokenCache, ofType: CachedToken.self)
        } catch {
            Logger.error("Error removing token cache \(error)")
        }
    }
}
