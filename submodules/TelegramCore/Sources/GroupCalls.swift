import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit
import SyncCore

public struct GroupCallInfo: Equatable {
    public var id: Int64
    public var accessHash: Int64
    public var participantCount: Int
    public var clientParams: String?
    public var streamDcId: Int32?
    public var title: String?
    public var recordingStartTimestamp: Int32?
    public var sortAscending: Bool
    
    public init(
        id: Int64,
        accessHash: Int64,
        participantCount: Int,
        clientParams: String?,
        streamDcId: Int32?,
        title: String?,
        recordingStartTimestamp: Int32?,
        sortAscending: Bool
    ) {
        self.id = id
        self.accessHash = accessHash
        self.participantCount = participantCount
        self.clientParams = clientParams
        self.streamDcId = streamDcId
        self.title = title
        self.recordingStartTimestamp = recordingStartTimestamp
        self.sortAscending = sortAscending
    }
}

public struct GroupCallSummary: Equatable {
    public var info: GroupCallInfo
    public var topParticipants: [GroupCallParticipantsContext.Participant]
}

extension GroupCallInfo {
    init?(_ call: Api.GroupCall) {
        switch call {
        case let .groupCall(flags, id, accessHash, participantCount, params, title, streamDcId, recordStartDate, _):
            var clientParams: String?
            if let params = params {
                switch params {
                case let .dataJSON(data):
                    clientParams = data
                }
            }
            self.init(
                id: id,
                accessHash: accessHash,
                participantCount: Int(participantCount),
                clientParams: clientParams,
                streamDcId: streamDcId,
                title: title,
                recordingStartTimestamp: recordStartDate,
                sortAscending: (flags & (1 << 6)) != 0
            )
        case .groupCallDiscarded:
            return nil
        }
    }
}

public enum GetCurrentGroupCallError {
    case generic
}

public func getCurrentGroupCall(account: Account, callId: Int64, accessHash: Int64) -> Signal<GroupCallSummary?, GetCurrentGroupCallError> {
    return account.network.request(Api.functions.phone.getGroupCall(call: .inputGroupCall(id: callId, accessHash: accessHash)))
    |> mapError { _ -> GetCurrentGroupCallError in
        return .generic
    }
    |> mapToSignal { result -> Signal<GroupCallSummary?, GetCurrentGroupCallError> in
        switch result {
        case let .groupCall(call, participants, _, chats, users):
            return account.postbox.transaction { transaction -> GroupCallSummary? in
                guard let info = GroupCallInfo(call) else {
                    return nil
                }
                
                var peers: [Peer] = []
                var peerPresences: [PeerId: PeerPresence] = [:]
                
                for user in users {
                    let telegramUser = TelegramUser(user: user)
                    peers.append(telegramUser)
                    if let presence = TelegramUserPresence(apiUser: user) {
                        peerPresences[telegramUser.id] = presence
                    }
                }
                
                for chat in chats {
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        peers.append(peer)
                    }
                }
                
                updatePeers(transaction: transaction, peers: peers, update: { _, updated -> Peer in
                    return updated
                })
                updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                
                var parsedParticipants: [GroupCallParticipantsContext.Participant] = []
                
                loop: for participant in participants {
                    switch participant {
                    case let .groupCallParticipant(flags, apiPeerId, date, activeDate, source, volume, about, raiseHandRating):
                        let peerId: PeerId
                        switch apiPeerId {
                            case let .peerUser(userId):
                                peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                            case let .peerChat(chatId):
                                peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                            case let .peerChannel(channelId):
                                peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                        }
                        
                        let ssrc = UInt32(bitPattern: source)
                        guard let peer = transaction.getPeer(peerId) else {
                            continue loop
                        }
                        let muted = (flags & (1 << 0)) != 0
                        let mutedByYou = (flags & (1 << 9)) != 0
                        var muteState: GroupCallParticipantsContext.Participant.MuteState?
                        if muted {
                            let canUnmute = (flags & (1 << 2)) != 0
                            muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: canUnmute, mutedByYou: mutedByYou)
                        } else if mutedByYou {
                            muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: false, mutedByYou: mutedByYou)
                        }
                        let jsonParams: String? = nil
                        /*if let params = params {
                            switch params {
                            case let .dataJSON(data):
                                jsonParams = data
                            }
                        }*/
                        parsedParticipants.append(GroupCallParticipantsContext.Participant(
                            peer: peer,
                            ssrc: ssrc,
                            jsonParams: jsonParams,
                            joinTimestamp: date,
                            raiseHandRating: raiseHandRating,
                            hasRaiseHand: raiseHandRating != nil,
                            activityTimestamp: activeDate.flatMap(Double.init),
                            activityRank: nil,
                            muteState: muteState,
                            volume: volume,
                            about: about
                        ))
                    }
                }
                
                return GroupCallSummary(
                    info: info,
                    topParticipants: parsedParticipants
                )
            }
            |> mapError { _ -> GetCurrentGroupCallError in
            }
        }
    }
}

public enum CreateGroupCallError {
    case generic
    case anonymousNotAllowed
}

public func createGroupCall(account: Account, peerId: PeerId) -> Signal<GroupCallInfo, CreateGroupCallError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        let callPeer = transaction.getPeer(peerId).flatMap(apiInputPeer)
        return callPeer
    }
    |> castError(CreateGroupCallError.self)
    |> mapToSignal { inputPeer -> Signal<GroupCallInfo, CreateGroupCallError> in
        guard let inputPeer = inputPeer else {
            return .fail(.generic)
        }
        
        return account.network.request(Api.functions.phone.createGroupCall(peer: inputPeer, randomId: Int32.random(in: Int32.min ... Int32.max)))
        |> mapError { error -> CreateGroupCallError in
            if error.errorDescription == "ANONYMOUS_CALLS_DISABLED" {
                return .anonymousNotAllowed
            }
            return .generic
        }
        |> mapToSignal { result -> Signal<GroupCallInfo, CreateGroupCallError> in
            var parsedCall: GroupCallInfo?
            loop: for update in result.allUpdates {
                switch update {
                case let .updateGroupCall(_, call):
                    parsedCall = GroupCallInfo(call)
                    break loop
                default:
                    break
                }
            }
            
            guard let callInfo = parsedCall else {
                return .fail(.generic)
            }
            
            return account.postbox.transaction { transaction -> GroupCallInfo in
                transaction.updatePeerCachedData(peerIds: Set([peerId]), update: { _, cachedData -> CachedPeerData? in
                    if let cachedData = cachedData as? CachedChannelData {
                        return cachedData.withUpdatedActiveCall(CachedChannelData.ActiveCall(id: callInfo.id, accessHash: callInfo.accessHash, title: callInfo.title))
                    } else if let cachedData = cachedData as? CachedGroupData {
                        return cachedData.withUpdatedActiveCall(CachedChannelData.ActiveCall(id: callInfo.id, accessHash: callInfo.accessHash, title: callInfo.title))
                    } else {
                        return cachedData
                    }
                })
                
                account.stateManager.addUpdates(result)
                
                return callInfo
            }
            |> castError(CreateGroupCallError.self)
        }
    }
}

public enum GetGroupCallParticipantsError {
    case generic
}

public func getGroupCallParticipants(account: Account, callId: Int64, accessHash: Int64, offset: String, ssrcs: [UInt32], limit: Int32, sortAscending: Bool?) -> Signal<GroupCallParticipantsContext.State, GetGroupCallParticipantsError> {
    let sortAscendingValue: Signal<Bool, GetGroupCallParticipantsError>
    if let sortAscending = sortAscending {
        sortAscendingValue = .single(sortAscending)
    } else {
        sortAscendingValue = getCurrentGroupCall(account: account, callId: callId, accessHash: accessHash)
        |> mapError { _ -> GetGroupCallParticipantsError in
            return .generic
        }
        |> mapToSignal { result -> Signal<Bool, GetGroupCallParticipantsError> in
            guard let result = result else {
                return .fail(.generic)
            }
            return .single(result.info.sortAscending)
        }
    }

    return combineLatest(
        account.network.request(Api.functions.phone.getGroupParticipants(call: .inputGroupCall(id: callId, accessHash: accessHash), ids: [], sources: ssrcs.map { Int32(bitPattern: $0) }, offset: offset, limit: limit))
        |> mapError { _ -> GetGroupCallParticipantsError in
            return .generic
        },
        sortAscendingValue
    )
    |> mapToSignal { result, sortAscendingValue -> Signal<GroupCallParticipantsContext.State, GetGroupCallParticipantsError> in
        return account.postbox.transaction { transaction -> GroupCallParticipantsContext.State in
            var parsedParticipants: [GroupCallParticipantsContext.Participant] = []
            let totalCount: Int
            let version: Int32
            let nextParticipantsFetchOffset: String?
            
            switch result {
            case let .groupParticipants(count, participants, nextOffset, chats, users, apiVersion):
                totalCount = Int(count)
                version = apiVersion
                
                if participants.count != 0 && !nextOffset.isEmpty {
                    nextParticipantsFetchOffset = nextOffset
                } else {
                    nextParticipantsFetchOffset = nil
                }
                
                var peers: [Peer] = []
                var peerPresences: [PeerId: PeerPresence] = [:]
                
                for user in users {
                    let telegramUser = TelegramUser(user: user)
                    peers.append(telegramUser)
                    if let presence = TelegramUserPresence(apiUser: user) {
                        peerPresences[telegramUser.id] = presence
                    }
                }
                
                for chat in chats {
                    if let peer = parseTelegramGroupOrChannel(chat: chat) {
                        peers.append(peer)
                    }
                }
                
                updatePeers(transaction: transaction, peers: peers, update: { _, updated -> Peer in
                    return updated
                })
                updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)
                
                loop: for participant in participants {
                    switch participant {
                    case let .groupCallParticipant(flags, apiPeerId, date, activeDate, source, volume, about, raiseHandRating):
                        let peerId: PeerId
                        switch apiPeerId {
                            case let .peerUser(userId):
                                peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                            case let .peerChat(chatId):
                                peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                            case let .peerChannel(channelId):
                                peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                        }
                        let ssrc = UInt32(bitPattern: source)
                        guard let peer = transaction.getPeer(peerId) else {
                            continue loop
                        }
                        let muted = (flags & (1 << 0)) != 0
                        let mutedByYou = (flags & (1 << 9)) != 0
                        var muteState: GroupCallParticipantsContext.Participant.MuteState?
                        if muted {
                            let canUnmute = (flags & (1 << 2)) != 0
                            muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: canUnmute, mutedByYou: mutedByYou)
                        } else if mutedByYou {
                            muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: false, mutedByYou: mutedByYou)
                        }
                        let jsonParams: String? = nil
                        /*if let params = params {
                            switch params {
                            case let .dataJSON(data):
                                jsonParams = data
                            }
                        }*/
                        parsedParticipants.append(GroupCallParticipantsContext.Participant(
                            peer: peer,
                            ssrc: ssrc,
                            jsonParams: jsonParams,
                            joinTimestamp: date,
                            raiseHandRating: raiseHandRating,
                            hasRaiseHand: raiseHandRating != nil,
                            activityTimestamp: activeDate.flatMap(Double.init),
                            activityRank: nil,
                            muteState: muteState,
                            volume: volume,
                            about: about
                        ))
                    }
                }
            }

            parsedParticipants.sort(by: { GroupCallParticipantsContext.Participant.compare(lhs: $0, rhs: $1, sortAscending: sortAscendingValue) })
            
            return GroupCallParticipantsContext.State(
                participants: parsedParticipants,
                nextParticipantsFetchOffset: nextParticipantsFetchOffset,
                adminIds: Set(),
                isCreator: false,
                defaultParticipantsAreMuted: GroupCallParticipantsContext.State.DefaultParticipantsAreMuted(isMuted: false, canChange: false),
                sortAscending: sortAscendingValue,
                recordingStartTimestamp: nil,
                title: nil,
                totalCount: totalCount,
                version: version
            )
        }
        |> castError(GetGroupCallParticipantsError.self)
    }
}

public enum JoinGroupCallError {
    case generic
    case anonymousNotAllowed
    case tooManyParticipants
    case invalidJoinAsPeer
}

public struct JoinGroupCallResult {
    public enum ConnectionMode {
        case rtc
        case broadcast
    }
    
    public var callInfo: GroupCallInfo
    public var state: GroupCallParticipantsContext.State
    public var connectionMode: ConnectionMode
}

public func joinGroupCall(account: Account, peerId: PeerId, joinAs: PeerId?, callId: Int64, accessHash: Int64, preferMuted: Bool, joinPayload: String, peerAdminIds: Signal<[PeerId], NoError>, inviteHash: String? = nil) -> Signal<JoinGroupCallResult, JoinGroupCallError> {
    return account.postbox.transaction { transaction -> Api.InputPeer? in
        if let joinAs = joinAs {
            return transaction.getPeer(joinAs).flatMap(apiInputPeer)
        } else {
            return .inputPeerSelf
        }
    }
    |> castError(JoinGroupCallError.self)
    |> mapToSignal { inputJoinAs in
        guard let inputJoinAs = inputJoinAs else {
            return .fail(.generic)
        }
        
        var flags: Int32 = 0
        if preferMuted {
            flags |= (1 << 0)
        }
        if let _ = inviteHash {
            flags |= (1 << 1)
        }

        let joinRequest = account.network.request(Api.functions.phone.joinGroupCall(flags: flags, call: .inputGroupCall(id: callId, accessHash: accessHash), joinAs: inputJoinAs, inviteHash: inviteHash, params: .dataJSON(data: joinPayload)))
        |> mapError { error -> JoinGroupCallError in
            if error.errorDescription == "GROUPCALL_ANONYMOUS_FORBIDDEN" {
                return .anonymousNotAllowed
            } else if error.errorDescription == "GROUPCALL_PARTICIPANTS_TOO_MUCH" {
                return .tooManyParticipants
            } else if error.errorDescription == "JOIN_AS_PEER_INVALID" {
                return .invalidJoinAsPeer
            }
            return .generic
        }

        let getParticipantsRequest = getGroupCallParticipants(account: account, callId: callId, accessHash: accessHash, offset: "", ssrcs: [], limit: 100, sortAscending: true)
        |> mapError { _ -> JoinGroupCallError in
            return .generic
        }
        
        return combineLatest(
            joinRequest,
            getParticipantsRequest
        )
        |> mapToSignal { updates, participantsState -> Signal<JoinGroupCallResult, JoinGroupCallError> in            
            let peer = account.postbox.transaction { transaction -> Peer? in
                return transaction.getPeer(peerId)
            }
            |> castError(JoinGroupCallError.self)
            
            return combineLatest(
                peerAdminIds |> castError(JoinGroupCallError.self) |> take(1),
                peer
            )
            |> mapToSignal { peerAdminIds, peer -> Signal<JoinGroupCallResult, JoinGroupCallError> in
                guard let peer = peer else {
                    return .fail(.generic)
                }
                
                var state = participantsState
                if let channel = peer as? TelegramChannel {
                    state.isCreator = channel.flags.contains(.isCreator)
                } else if let group = peer as? TelegramGroup {
                    if case .creator = group.role {
                        state.isCreator = true
                    } else {
                        state.isCreator = false
                    }
                }
                
                account.stateManager.addUpdates(updates)
                
                var maybeParsedCall: GroupCallInfo?
                loop: for update in updates.allUpdates {
                    switch update {
                    case let .updateGroupCall(_, call):
                        maybeParsedCall = GroupCallInfo(call)
                        
                        switch call {
                        case let .groupCall(flags, _, _, _, _, title, _, recordStartDate, _):
                            let isMuted = (flags & (1 << 1)) != 0
                            let canChange = (flags & (1 << 2)) != 0
                            state.defaultParticipantsAreMuted = GroupCallParticipantsContext.State.DefaultParticipantsAreMuted(isMuted: isMuted, canChange: canChange)
                            state.title = title
                            state.recordingStartTimestamp = recordStartDate
                        default:
                            break
                        }
                        
                        break loop
                    default:
                        break
                    }
                }
                
                guard let parsedCall = maybeParsedCall else {
                    return .fail(.generic)
                }

                state.sortAscending = parsedCall.sortAscending
                
                let apiUsers: [Api.User] = []
                
                state.adminIds = Set(peerAdminIds)
                    
                var peers: [Peer] = []
                var peerPresences: [PeerId: PeerPresence] = [:]

                for user in apiUsers {
                    let telegramUser = TelegramUser(user: user)
                    peers.append(telegramUser)
                    if let presence = TelegramUserPresence(apiUser: user) {
                        peerPresences[telegramUser.id] = presence
                    }
                }

                let connectionMode: JoinGroupCallResult.ConnectionMode
                if let clientParams = parsedCall.clientParams, let clientParamsData = clientParams.data(using: .utf8), let dict = (try? JSONSerialization.jsonObject(with: clientParamsData, options: [])) as? [String: Any] {
                    if let stream = dict["stream"] as? Bool, stream {
                        connectionMode = .broadcast
                    } else {
                        connectionMode = .rtc
                    }
                } else {
                    connectionMode = .broadcast
                }

                return account.postbox.transaction { transaction -> JoinGroupCallResult in
                    transaction.updatePeerCachedData(peerIds: Set([peerId]), update: { _, cachedData -> CachedPeerData? in
                        if let cachedData = cachedData as? CachedChannelData {
                            return cachedData.withUpdatedCallJoinPeerId(joinAs)
                        } else if let cachedData = cachedData as? CachedGroupData {
                            return cachedData.withUpdatedCallJoinPeerId(joinAs)
                        } else {
                            return cachedData
                        }
                    })

                    var state = state

                    for update in updates.allUpdates {
                        switch update {
                        case let .updateGroupCallParticipants(_, participants, _):
                            loop: for participant in participants {
                                switch participant {
                                case let .groupCallParticipant(flags, apiPeerId, date, activeDate, source, volume, about, raiseHandRating):
                                    let peerId: PeerId
                                    switch apiPeerId {
                                        case let .peerUser(userId):
                                            peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                                        case let .peerChat(chatId):
                                            peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                                        case let .peerChannel(channelId):
                                            peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                                    }
                                    let ssrc = UInt32(bitPattern: source)
                                    guard let peer = transaction.getPeer(peerId) else {
                                        continue loop
                                    }
                                    let muted = (flags & (1 << 0)) != 0
                                    let mutedByYou = (flags & (1 << 9)) != 0
                                    var muteState: GroupCallParticipantsContext.Participant.MuteState?
                                    if muted {
                                        let canUnmute = (flags & (1 << 2)) != 0
                                        muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: canUnmute, mutedByYou: mutedByYou)
                                    } else if mutedByYou {
                                        muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: false, mutedByYou: mutedByYou)
                                    }
                                    let jsonParams: String? = nil
                                    /*if let params = params {
                                        switch params {
                                        case let .dataJSON(data):
                                            jsonParams = data
                                        }
                                    }*/
                                    if !state.participants.contains(where: { $0.peer.id == peer.id }) {
                                        state.participants.append(GroupCallParticipantsContext.Participant(
                                            peer: peer,
                                            ssrc: ssrc,
                                            jsonParams: jsonParams,
                                            joinTimestamp: date,
                                            raiseHandRating: raiseHandRating,
                                            hasRaiseHand: raiseHandRating != nil,
                                            activityTimestamp: activeDate.flatMap(Double.init),
                                            activityRank: nil,
                                            muteState: muteState,
                                            volume: volume,
                                            about: about
                                        ))
                                    }
                                }
                            }
                        default:
                            break
                        }
                    }

                    state.participants.sort(by: { GroupCallParticipantsContext.Participant.compare(lhs: $0, rhs: $1, sortAscending: state.sortAscending) })

                    updatePeers(transaction: transaction, peers: peers, update: { _, updated -> Peer in
                        return updated
                    })
                    updatePeerPresences(transaction: transaction, accountPeerId: account.peerId, peerPresences: peerPresences)

                    return JoinGroupCallResult(
                        callInfo: parsedCall,
                        state: state,
                        connectionMode: connectionMode
                    )
                }
                |> castError(JoinGroupCallError.self)
            }
        }
    }
    
}

public enum LeaveGroupCallError {
    case generic
}

public func leaveGroupCall(account: Account, callId: Int64, accessHash: Int64, source: UInt32) -> Signal<Never, LeaveGroupCallError> {
    return account.network.request(Api.functions.phone.leaveGroupCall(call: .inputGroupCall(id: callId, accessHash: accessHash), source: Int32(bitPattern: source)))
    |> mapError { _ -> LeaveGroupCallError in
        return .generic
    }
    |> mapToSignal { result -> Signal<Never, LeaveGroupCallError> in
        account.stateManager.addUpdates(result)
        
        return .complete()
    }
}

public enum StopGroupCallError {
    case generic
}

public func stopGroupCall(account: Account, peerId: PeerId, callId: Int64, accessHash: Int64) -> Signal<Never, StopGroupCallError> {
    return account.network.request(Api.functions.phone.discardGroupCall(call: .inputGroupCall(id: callId, accessHash: accessHash)))
    |> mapError { _ -> StopGroupCallError in
        return .generic
    }
    |> mapToSignal { result -> Signal<Never, StopGroupCallError> in
        return account.postbox.transaction { transaction -> Void in
            transaction.updatePeerCachedData(peerIds: Set([peerId]), update: { _, cachedData -> CachedPeerData? in
                if let cachedData = cachedData as? CachedChannelData {
                    return cachedData.withUpdatedActiveCall(nil).withUpdatedCallJoinPeerId(nil)
                } else if let cachedData = cachedData as? CachedGroupData {
                    return cachedData.withUpdatedActiveCall(nil).withUpdatedCallJoinPeerId(nil)
                } else {
                    return cachedData
                }
            })
            if var peer = transaction.getPeer(peerId) as? TelegramChannel {
                var flags = peer.flags
                flags.remove(.hasVoiceChat)
                flags.remove(.hasActiveVoiceChat)
                peer = peer.withUpdatedFlags(flags)
                updatePeers(transaction: transaction, peers: [peer], update: { _, updated in
                    return updated
                })
            }
            if var peer = transaction.getPeer(peerId) as? TelegramGroup {
                var flags = peer.flags
                flags.remove(.hasVoiceChat)
                flags.remove(.hasActiveVoiceChat)
                peer = peer.updateFlags(flags: flags, version: peer.version)
                updatePeers(transaction: transaction, peers: [peer], update: { _, updated in
                    return updated
                })
            }
            
            account.stateManager.addUpdates(result)
        }
        |> castError(StopGroupCallError.self)
        |> ignoreValues
    }
}

public enum CheckGroupCallResult {
    case success
    case restart
}

public func checkGroupCall(account: Account, callId: Int64, accessHash: Int64, ssrc: Int32) -> Signal<CheckGroupCallResult, NoError> {
    return account.network.request(Api.functions.phone.checkGroupCall(call: .inputGroupCall(id: callId, accessHash: accessHash), source: ssrc))
    |> `catch` { _ -> Signal<Api.Bool, NoError> in
        return .single(.boolFalse)
    }
    |> map { result -> CheckGroupCallResult in
        #if DEBUG
        //return .restart
        #endif
        switch result {
        case .boolTrue:
            return .success
        case .boolFalse:
            return .restart
        }
    }
}

private func binaryInsertionIndex(_ inputArr: [GroupCallParticipantsContext.Participant], searchItem: Int32) -> Int {
    var lo = 0
    var hi = inputArr.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        if inputArr[mid].joinTimestamp < searchItem {
            lo = mid + 1
        } else if searchItem < inputArr[mid].joinTimestamp {
            hi = mid - 1
        } else {
            return mid
        }
    }
    return lo
}

public final class GroupCallParticipantsContext {
    public struct Participant: Equatable, CustomStringConvertible {
        public struct MuteState: Equatable {
            public var canUnmute: Bool
            public var mutedByYou: Bool
            
            public init(canUnmute: Bool, mutedByYou: Bool) {
                self.canUnmute = canUnmute
                self.mutedByYou = mutedByYou
            }
        }
        
        public var peer: Peer
        public var ssrc: UInt32?
        public var jsonParams: String?
        public var joinTimestamp: Int32
        public var raiseHandRating: Int64?
        public var hasRaiseHand: Bool
        public var activityTimestamp: Double?
        public var activityRank: Int?
        public var muteState: MuteState?
        public var volume: Int32?
        public var about: String?
        
        public init(
            peer: Peer,
            ssrc: UInt32?,
            jsonParams: String?,
            joinTimestamp: Int32,
            raiseHandRating: Int64?,
            hasRaiseHand: Bool,
            activityTimestamp: Double?,
            activityRank: Int?,
            muteState: MuteState?,
            volume: Int32?,
            about: String?
        ) {
            self.peer = peer
            self.ssrc = ssrc
            self.jsonParams = jsonParams
            self.joinTimestamp = joinTimestamp
            self.raiseHandRating = raiseHandRating
            self.hasRaiseHand = hasRaiseHand
            self.activityTimestamp = activityTimestamp
            self.activityRank = activityRank
            self.muteState = muteState
            self.volume = volume
            self.about = about
        }

        public var description: String {
            return "Participant(peer: \(peer.id): \(peer.debugDisplayTitle), ssrc: \(String(describing: self.ssrc))"
        }
        
        public mutating func mergeActivity(from other: Participant, mergeActivityTimestamp: Bool) {
            self.activityRank = other.activityRank
            if mergeActivityTimestamp {
                self.activityTimestamp = other.activityTimestamp
            }
        }
        
        public static func ==(lhs: Participant, rhs: Participant) -> Bool {
            if !lhs.peer.isEqual(rhs.peer) {
                return false
            }
            if lhs.ssrc != rhs.ssrc {
                return false
            }
            if lhs.joinTimestamp != rhs.joinTimestamp {
                return false
            }
            if lhs.raiseHandRating != rhs.raiseHandRating {
                return false
            }
            if lhs.hasRaiseHand != rhs.hasRaiseHand {
                return false
            }
            if lhs.activityTimestamp != rhs.activityTimestamp {
                return false
            }
            if lhs.activityRank != rhs.activityRank {
                return false
            }
            if lhs.muteState != rhs.muteState {
                return false
            }
            if lhs.volume != rhs.volume {
                return false
            }
            if lhs.about != rhs.about {
                return false
            }
            if lhs.raiseHandRating != rhs.raiseHandRating {
                return false
            }
            return true
        }
        
        public static func compare(lhs: Participant, rhs: Participant, sortAscending: Bool) -> Bool {
            if let lhsActivityRank = lhs.activityRank, let rhsActivityRank = rhs.activityRank {
                if lhsActivityRank != rhsActivityRank {
                    return lhsActivityRank < rhsActivityRank
                }
            } else if lhs.activityRank != nil {
                return true
            } else if rhs.activityRank != nil {
                return false
            }
            
            if let lhsActivityTimestamp = lhs.activityTimestamp, let rhsActivityTimestamp = rhs.activityTimestamp {
                if lhsActivityTimestamp != rhsActivityTimestamp {
                    return lhsActivityTimestamp > rhsActivityTimestamp
                }
            } else if lhs.activityTimestamp != nil {
                return true
            } else if rhs.activityTimestamp != nil {
                return false
            }
            
            if let lhsRaiseHandRating = lhs.raiseHandRating, let rhsRaiseHandRating = rhs.raiseHandRating {
                if lhsRaiseHandRating != rhsRaiseHandRating {
                    return lhsRaiseHandRating > rhsRaiseHandRating
                }
            } else if lhs.raiseHandRating != nil {
                return true
            } else if rhs.raiseHandRating != nil {
                return false
            }
            
            if lhs.joinTimestamp != rhs.joinTimestamp {
                if sortAscending {
                    return lhs.joinTimestamp < rhs.joinTimestamp
                } else {
                    return lhs.joinTimestamp > rhs.joinTimestamp
                }
            }
            
            return lhs.peer.id < rhs.peer.id
        }
    }
    
    public struct State: Equatable {
        public struct DefaultParticipantsAreMuted: Equatable {
            public var isMuted: Bool
            public var canChange: Bool
        }
        
        public var participants: [Participant]
        public var nextParticipantsFetchOffset: String?
        public var adminIds: Set<PeerId>
        public var isCreator: Bool
        public var defaultParticipantsAreMuted: DefaultParticipantsAreMuted
        public var sortAscending: Bool
        public var recordingStartTimestamp: Int32?
        public var title: String?
        public var totalCount: Int
        public var version: Int32
        
        public mutating func mergeActivity(from other: State, myPeerId: PeerId?, previousMyPeerId: PeerId?, mergeActivityTimestamps: Bool) {
            var indexMap: [PeerId: Int] = [:]
            for i in 0 ..< other.participants.count {
                indexMap[other.participants[i].peer.id] = i
            }
            
            for i in 0 ..< self.participants.count {
                if let index = indexMap[self.participants[i].peer.id] {
                    self.participants[i].mergeActivity(from: other.participants[index], mergeActivityTimestamp: mergeActivityTimestamps)
                    if self.participants[i].peer.id == myPeerId || self.participants[i].peer.id == previousMyPeerId {
                        self.participants[i].joinTimestamp = other.participants[index].joinTimestamp
                    }
                }
            }
            
            self.participants.sort(by: { GroupCallParticipantsContext.Participant.compare(lhs: $0, rhs: $1, sortAscending: self.sortAscending) })
        }
    }
    
    private struct OverlayState: Equatable {
        struct MuteStateChange: Equatable {
            var state: Participant.MuteState?
            var volume: Int32?
            var disposable: Disposable
            
            static func ==(lhs: MuteStateChange, rhs: MuteStateChange) -> Bool {
                if lhs.state != rhs.state {
                    return false
                }
                if lhs.volume != rhs.volume {
                    return false
                }
                if lhs.disposable !== rhs.disposable {
                    return false
                }
                return true
            }
        }
        
        var pendingMuteStateChanges: [PeerId: MuteStateChange] = [:]
        
        var isEmpty: Bool {
            if !self.pendingMuteStateChanges.isEmpty {
                return false
            }
            return true
        }
    }
    
    private struct InternalState: Equatable {
        var state: State
        var overlayState: OverlayState
    }
    
    public enum Update {
        public struct StateUpdate {
            public struct ParticipantUpdate {
                public enum ParticipationStatusChange {
                    case none
                    case joined
                    case left
                }
                
                public var peerId: PeerId
                public var ssrc: UInt32?
                public var jsonParams: String?
                public var joinTimestamp: Int32
                public var activityTimestamp: Double?
                public var raiseHandRating: Int64?
                public var muteState: Participant.MuteState?
                public var participationStatusChange: ParticipationStatusChange
                public var volume: Int32?
                public var about: String?
                public var isMin: Bool
                
                init(
                    peerId: PeerId,
                    ssrc: UInt32?,
                    jsonParams: String?,
                    joinTimestamp: Int32,
                    activityTimestamp: Double?,
                    raiseHandRating: Int64?,
                    muteState: Participant.MuteState?,
                    participationStatusChange: ParticipationStatusChange,
                    volume: Int32?,
                    about: String?,
                    isMin: Bool
                ) {
                    self.peerId = peerId
                    self.ssrc = ssrc
                    self.jsonParams = jsonParams
                    self.joinTimestamp = joinTimestamp
                    self.activityTimestamp = activityTimestamp
                    self.raiseHandRating = raiseHandRating
                    self.muteState = muteState
                    self.participationStatusChange = participationStatusChange
                    self.volume = volume
                    self.about = about
                    self.isMin = isMin
                }
            }
            
            public var participantUpdates: [ParticipantUpdate]
            public var version: Int32
            
            public var removePendingMuteStates: Set<PeerId>
        }
        
        case state(update: StateUpdate)
        case call(isTerminated: Bool, defaultParticipantsAreMuted: State.DefaultParticipantsAreMuted, title: String?, recordingStartTimestamp: Int32?)
    }
    
    public final class MemberEvent {
        public let peerId: PeerId
        public let joined: Bool
        
        public init(peerId: PeerId, joined: Bool) {
            self.peerId = peerId
            self.joined = joined
        }
    }
    
    private let account: Account
    public let myPeerId: PeerId
    public let id: Int64
    public let accessHash: Int64
    
    private var hasReceivedSpeakingParticipantsReport: Bool = false
    
    private var stateValue: InternalState {
        didSet {
            if self.stateValue != oldValue {
                self.statePromise.set(self.stateValue)
            }
        }
    }
    private let statePromise: ValuePromise<InternalState>
    
    public var immediateState: State?
    
    public var state: Signal<State, NoError> {
        let accountPeerId = self.account.peerId
        return self.statePromise.get()
        |> map { state -> State in
            var publicState = state.state
            var sortAgain = false
            let canSeeHands = state.state.isCreator || state.state.adminIds.contains(accountPeerId)
            for i in 0 ..< publicState.participants.count {
                if let pendingMuteState = state.overlayState.pendingMuteStateChanges[publicState.participants[i].peer.id] {
                    publicState.participants[i].muteState = pendingMuteState.state
                    publicState.participants[i].volume = pendingMuteState.volume
                }
                if !canSeeHands && publicState.participants[i].raiseHandRating != nil {
                    publicState.participants[i].raiseHandRating = nil
                    sortAgain = true
                }
            }
            if sortAgain {
                publicState.participants.sort(by: { GroupCallParticipantsContext.Participant.compare(lhs: $0, rhs: $1, sortAscending: publicState.sortAscending) })
            }
            return publicState
        }
        |> beforeNext { [weak self] next in
            Queue.mainQueue().async {
                self?.immediateState = next
            }
        }
    }
    
    private var activeSpeakersValue: Set<PeerId> = Set() {
        didSet {
            if self.activeSpeakersValue != oldValue {
                self.activeSpeakersPromise.set(self.activeSpeakersValue)
            }
        }
    }
    private let activeSpeakersPromise = ValuePromise<Set<PeerId>>(Set())
    public var activeSpeakers: Signal<Set<PeerId>, NoError> {
        return self.activeSpeakersPromise.get()
    }
    
    private let memberEventsPipe = ValuePipe<MemberEvent>()
    public var memberEvents: Signal<MemberEvent, NoError> {
        return self.memberEventsPipe.signal()
    }
    
    private var updateQueue: [Update.StateUpdate] = []
    private var isProcessingUpdate: Bool = false
    private let disposable = MetaDisposable()
    
    private let updatesDisposable = MetaDisposable()
    private var activitiesDisposable: Disposable?
    
    private var isLoadingMore: Bool = false
    private var shouldResetStateFromServer: Bool = false
    private var missingSsrcs = Set<UInt32>()

    private var activityRankResetTimer: SwiftSignalKit.Timer?
    
    private let updateDefaultMuteDisposable = MetaDisposable()
    private let resetInviteLinksDisposable = MetaDisposable()
    private let updateShouldBeRecordingDisposable = MetaDisposable()

    public struct ServiceState {
        fileprivate var nextActivityRank: Int = 0
    }

    public private(set) var serviceState: ServiceState
    
    public init(account: Account, peerId: PeerId, myPeerId: PeerId, id: Int64, accessHash: Int64, state: State, previousServiceState: ServiceState?) {
        self.account = account
        self.myPeerId = myPeerId
        self.id = id
        self.accessHash = accessHash
        self.stateValue = InternalState(state: state, overlayState: OverlayState())
        self.statePromise = ValuePromise<InternalState>(self.stateValue)
        self.serviceState = previousServiceState ?? ServiceState()
        
        self.updatesDisposable.set((self.account.stateManager.groupCallParticipantUpdates
        |> deliverOnMainQueue).start(next: { [weak self] updates in
            guard let strongSelf = self else {
                return
            }
            var filteredUpdates: [Update] = []
            for (callId, update) in updates {
                if callId == id {
                    filteredUpdates.append(update)
                }
            }
            if !filteredUpdates.isEmpty {
                strongSelf.addUpdates(updates: filteredUpdates)
            }
        }))
        
        let activityCategory: PeerActivitySpace.Category = .voiceChat
        self.activitiesDisposable = (self.account.peerInputActivities(peerId: PeerActivitySpace(peerId: peerId, category: activityCategory))
        |> deliverOnMainQueue).start(next: { [weak self] activities in
            guard let strongSelf = self else {
                return
            }
        
            let peerIds = Set(activities.map { item -> PeerId in
                item.0
            })
            strongSelf.activeSpeakersValue = peerIds
            
            if !strongSelf.hasReceivedSpeakingParticipantsReport {
                var updatedParticipants = strongSelf.stateValue.state.participants
                var indexMap: [PeerId: Int] = [:]
                for i in 0 ..< updatedParticipants.count {
                    indexMap[updatedParticipants[i].peer.id] = i
                }
                var updated = false
                
                for (activityPeerId, activity) in activities {
                    if case let .speakingInGroupCall(intTimestamp) = activity {
                        let timestamp = Double(intTimestamp)
                        
                        if let index = indexMap[activityPeerId] {
                            if let activityTimestamp = updatedParticipants[index].activityTimestamp {
                                if activityTimestamp < timestamp {
                                    updatedParticipants[index].activityTimestamp = timestamp
                                    updated = true
                                }
                            } else {
                                updatedParticipants[index].activityTimestamp = timestamp
                                updated = true
                            }
                        }
                    }
                }
                
                if updated {
                    updatedParticipants.sort(by: { GroupCallParticipantsContext.Participant.compare(lhs: $0, rhs: $1, sortAscending: strongSelf.stateValue.state.sortAscending) })
                    
                    strongSelf.stateValue = InternalState(
                        state: State(
                            participants: updatedParticipants,
                            nextParticipantsFetchOffset: strongSelf.stateValue.state.nextParticipantsFetchOffset,
                            adminIds: strongSelf.stateValue.state.adminIds,
                            isCreator: strongSelf.stateValue.state.isCreator,
                            defaultParticipantsAreMuted: strongSelf.stateValue.state.defaultParticipantsAreMuted,
                            sortAscending: strongSelf.stateValue.state.sortAscending,
                            recordingStartTimestamp: strongSelf.stateValue.state.recordingStartTimestamp,
                            title: strongSelf.stateValue.state.title,
                            totalCount: strongSelf.stateValue.state.totalCount,
                            version: strongSelf.stateValue.state.version
                        ),
                        overlayState: strongSelf.stateValue.overlayState
                    )
                }
            }
        })
        
        self.activityRankResetTimer = SwiftSignalKit.Timer(timeout: 10.0, repeat: true, completion: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            
            var updated = false
            let timestamp = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970
            
            for i in 0 ..< strongSelf.stateValue.state.participants.count {
                if strongSelf.stateValue.state.participants[i].activityRank != nil {
                    var clearRank = false
                    if let activityTimestamp = strongSelf.stateValue.state.participants[i].activityTimestamp {
                        if activityTimestamp < timestamp - 60.0 {
                            clearRank = true
                        }
                    } else {
                        clearRank = true
                    }
                    if clearRank {
                        updated = true
                        strongSelf.stateValue.state.participants[i].activityRank = nil
                    }
                }
            }
            if updated {
                strongSelf.stateValue.state.participants.sort(by: { GroupCallParticipantsContext.Participant.compare(lhs: $0, rhs: $1, sortAscending: strongSelf.stateValue.state.sortAscending) })
            }
        }, queue: .mainQueue())
        self.activityRankResetTimer?.start()
    }
    
    deinit {
        self.disposable.dispose()
        self.updatesDisposable.dispose()
        self.activitiesDisposable?.dispose()
        self.updateDefaultMuteDisposable.dispose()
        self.updateShouldBeRecordingDisposable.dispose()
        self.activityRankResetTimer?.invalidate()
        resetInviteLinksDisposable.dispose()
    }
    
    public func addUpdates(updates: [Update]) {
        var stateUpdates: [Update.StateUpdate] = []
        for update in updates {
            if case let .state(update) = update {
                stateUpdates.append(update)
            } else if case let .call(_, defaultParticipantsAreMuted, title, recordingStartTimestamp) = update {
                var state = self.stateValue.state
                state.defaultParticipantsAreMuted = defaultParticipantsAreMuted
                state.recordingStartTimestamp = recordingStartTimestamp
                state.title = title
                
                self.stateValue.state = state
            }
        }
        
        if !stateUpdates.isEmpty {
            self.updateQueue.append(contentsOf: stateUpdates)
            self.beginProcessingUpdatesIfNeeded()
        }
    }
    
    private func takeNextActivityRank() -> Int {
        let value = self.serviceState.nextActivityRank
        self.serviceState.nextActivityRank += 1
        return value
    }

    public func updateAdminIds(_ adminIds: Set<PeerId>) {
        if self.stateValue.state.adminIds != adminIds {
            self.stateValue.state.adminIds = adminIds
        }
    }
    
    public func reportSpeakingParticipants(ids: [PeerId: UInt32]) {
        if !ids.isEmpty {
            self.hasReceivedSpeakingParticipantsReport = true
        }
        
        let strongSelf = self
        
        var updatedParticipants = strongSelf.stateValue.state.participants
        var indexMap: [PeerId: Int] = [:]
        for i in 0 ..< updatedParticipants.count {
            indexMap[updatedParticipants[i].peer.id] = i
        }
        var updated = false
        
        let timestamp = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970
        
        for (activityPeerId, _) in ids {
            if let index = indexMap[activityPeerId] {
                var updateTimestamp = false
                if let activityTimestamp = updatedParticipants[index].activityTimestamp {
                    if activityTimestamp < timestamp {
                        updateTimestamp = true
                    }
                } else {
                    updateTimestamp = true
                }
                if updateTimestamp {
                    updatedParticipants[index].activityTimestamp = timestamp
                    if updatedParticipants[index].activityRank == nil {
                        updatedParticipants[index].activityRank = self.takeNextActivityRank()
                    }
                    updated = true
                }
            }
        }
        
        if updated {
            updatedParticipants.sort(by: { GroupCallParticipantsContext.Participant.compare(lhs: $0, rhs: $1, sortAscending: strongSelf.stateValue.state.sortAscending) })
            
            strongSelf.stateValue = InternalState(
                state: State(
                    participants: updatedParticipants,
                    nextParticipantsFetchOffset: strongSelf.stateValue.state.nextParticipantsFetchOffset,
                    adminIds: strongSelf.stateValue.state.adminIds,
                    isCreator: strongSelf.stateValue.state.isCreator,
                    defaultParticipantsAreMuted: strongSelf.stateValue.state.defaultParticipantsAreMuted,
                    sortAscending: strongSelf.stateValue.state.sortAscending,
                    recordingStartTimestamp: strongSelf.stateValue.state.recordingStartTimestamp,
                    title: strongSelf.stateValue.state.title,
                    totalCount: strongSelf.stateValue.state.totalCount,
                    version: strongSelf.stateValue.state.version
                ),
                overlayState: strongSelf.stateValue.overlayState
            )
        }
        
        self.ensureHaveParticipants(ssrcs: Set(ids.map { $0.1 }))
    }
    
    public func ensureHaveParticipants(ssrcs: Set<UInt32>) {
        var missingSsrcs = Set<UInt32>()
        
        var existingSsrcs = Set<UInt32>()
        for participant in self.stateValue.state.participants {
            if let ssrc = participant.ssrc {
                existingSsrcs.insert(ssrc)
            }
        }
        
        for ssrc in ssrcs {
            if !existingSsrcs.contains(ssrc) {
                missingSsrcs.insert(ssrc)
            }
        }
        
        if !missingSsrcs.isEmpty {
            self.missingSsrcs.formUnion(missingSsrcs)
            self.loadMissingSsrcs()
        }
    }
    
    private func loadMissingSsrcs() {
        if self.missingSsrcs.isEmpty {
            return
        }
        if self.isLoadingMore {
            return
        }
        self.isLoadingMore = true
        
        let ssrcs = self.missingSsrcs

        Logger.shared.log("GroupCallParticipantsContext", "will request ssrcs=\(ssrcs)")
        
        self.disposable.set((getGroupCallParticipants(account: self.account, callId: self.id, accessHash: self.accessHash, offset: "", ssrcs: Array(ssrcs), limit: 100, sortAscending: true)
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isLoadingMore = false
            
            strongSelf.missingSsrcs.subtract(ssrcs)

            Logger.shared.log("GroupCallParticipantsContext", "did receive response for ssrcs=\(ssrcs), \(state.participants)")
            
            var updatedState = strongSelf.stateValue.state
            
            updatedState.participants = mergeAndSortParticipants(current: updatedState.participants, with: state.participants, sortAscending: updatedState.sortAscending)
            
            updatedState.totalCount = max(updatedState.totalCount, state.totalCount)
            updatedState.version = max(updatedState.version, updatedState.version)
            
            strongSelf.stateValue.state = updatedState
            
            if strongSelf.shouldResetStateFromServer {
                strongSelf.resetStateFromServer()
            } else {
                strongSelf.loadMissingSsrcs()
            }
        }))
    }
    
    private func beginProcessingUpdatesIfNeeded() {
        if self.isProcessingUpdate {
            return
        }
        if self.updateQueue.isEmpty {
            return
        }
        self.isProcessingUpdate = true
        let update = self.updateQueue.removeFirst()
        self.processUpdate(update: update)
    }
    
    private func endedProcessingUpdate() {
        assert(self.isProcessingUpdate)
        self.isProcessingUpdate = false
        self.beginProcessingUpdatesIfNeeded()
    }
    
    private func processUpdate(update: Update.StateUpdate) {
        if update.version < self.stateValue.state.version {
            for peerId in update.removePendingMuteStates {
                self.stateValue.overlayState.pendingMuteStateChanges.removeValue(forKey: peerId)
            }
            self.endedProcessingUpdate()
            return
        }
        
        if update.version > self.stateValue.state.version + 1 {
            for peerId in update.removePendingMuteStates {
                self.stateValue.overlayState.pendingMuteStateChanges.removeValue(forKey: peerId)
            }
            self.resetStateFromServer()
            return
        }
        
        let isVersionUpdate = update.version != self.stateValue.state.version
        
        let _ = (self.account.postbox.transaction { transaction -> [PeerId: Peer] in
            var peers: [PeerId: Peer] = [:]
            
            for participantUpdate in update.participantUpdates {
                if let peer = transaction.getPeer(participantUpdate.peerId) {
                    peers[peer.id] = peer
                }
            }
            
            return peers
        }
        |> deliverOnMainQueue).start(next: { [weak self] peers in
            guard let strongSelf = self else {
                return
            }
            
            var updatedParticipants = strongSelf.stateValue.state.participants
            var updatedTotalCount = strongSelf.stateValue.state.totalCount
            
            for participantUpdate in update.participantUpdates {
                if case .left = participantUpdate.participationStatusChange {
                    if let index = updatedParticipants.firstIndex(where: { $0.peer.id == participantUpdate.peerId }) {
                        updatedParticipants.remove(at: index)
                        updatedTotalCount = max(0, updatedTotalCount - 1)
                        strongSelf.memberEventsPipe.putNext(MemberEvent(peerId: participantUpdate.peerId, joined: false))
                    } else if isVersionUpdate {
                        updatedTotalCount = max(0, updatedTotalCount - 1)
                    }
                } else {
                    guard let peer = peers[participantUpdate.peerId] else {
                        assertionFailure()
                        continue
                    }
                    var previousJoinTimestamp: Int32?
                    var previousActivityTimestamp: Double?
                    var previousActivityRank: Int?
                    var previousMuteState: GroupCallParticipantsContext.Participant.MuteState?
                    var previousVolume: Int32?
                    if let index = updatedParticipants.firstIndex(where: { $0.peer.id == participantUpdate.peerId }) {
                        previousJoinTimestamp = updatedParticipants[index].joinTimestamp
                        previousActivityTimestamp = updatedParticipants[index].activityTimestamp
                        previousActivityRank = updatedParticipants[index].activityRank
                        previousMuteState = updatedParticipants[index].muteState
                        previousVolume = updatedParticipants[index].volume
                        updatedParticipants.remove(at: index)
                    } else if case .joined = participantUpdate.participationStatusChange {
                        updatedTotalCount += 1
                        strongSelf.memberEventsPipe.putNext(MemberEvent(peerId: participantUpdate.peerId, joined: true))
                    }

                    var activityTimestamp: Double?
                    if let previousActivityTimestamp = previousActivityTimestamp, let updatedActivityTimestamp = participantUpdate.activityTimestamp {
                        activityTimestamp = max(updatedActivityTimestamp, previousActivityTimestamp)
                    } else {
                        activityTimestamp = participantUpdate.activityTimestamp ?? previousActivityTimestamp
                    }

                    var volume = participantUpdate.volume
                    var muteState = participantUpdate.muteState
                    if participantUpdate.isMin {
                        if let previousMuteState = previousMuteState {
                            if previousMuteState.mutedByYou {
                                muteState = previousMuteState
                            }
                        }
                        if let previousVolume = previousVolume {
                            volume = previousVolume
                        }
                    }
                    
                    let participant = Participant(
                        peer: peer,
                        ssrc: participantUpdate.ssrc,
                        jsonParams: participantUpdate.jsonParams,
                        joinTimestamp: previousJoinTimestamp ?? participantUpdate.joinTimestamp,
                        raiseHandRating: participantUpdate.raiseHandRating,
                        hasRaiseHand: participantUpdate.raiseHandRating != nil,
                        activityTimestamp: activityTimestamp,
                        activityRank: previousActivityRank,
                        muteState: muteState,
                        volume: volume,
                        about: participantUpdate.about
                    )
                    updatedParticipants.append(participant)
                }
            }
            
            updatedTotalCount = max(updatedTotalCount, updatedParticipants.count)
            
            var updatedOverlayState = strongSelf.stateValue.overlayState
            for peerId in update.removePendingMuteStates {
                updatedOverlayState.pendingMuteStateChanges.removeValue(forKey: peerId)
            }
            
            let nextParticipantsFetchOffset = strongSelf.stateValue.state.nextParticipantsFetchOffset
            let adminIds = strongSelf.stateValue.state.adminIds
            let isCreator = strongSelf.stateValue.state.isCreator
            let defaultParticipantsAreMuted = strongSelf.stateValue.state.defaultParticipantsAreMuted
            let recordingStartTimestamp = strongSelf.stateValue.state.recordingStartTimestamp
            let title = strongSelf.stateValue.state.title
            
            updatedParticipants.sort(by: { GroupCallParticipantsContext.Participant.compare(lhs: $0, rhs: $1, sortAscending: strongSelf.stateValue.state.sortAscending) })
            
            strongSelf.stateValue = InternalState(
                state: State(
                    participants: updatedParticipants,
                    nextParticipantsFetchOffset: nextParticipantsFetchOffset,
                    adminIds: adminIds,
                    isCreator: isCreator,
                    defaultParticipantsAreMuted: defaultParticipantsAreMuted,
                    sortAscending: strongSelf.stateValue.state.sortAscending,
                    recordingStartTimestamp: recordingStartTimestamp,
                    title: title,
                    totalCount: updatedTotalCount,
                    version: update.version
                ),
                overlayState: updatedOverlayState
            )
            
            strongSelf.endedProcessingUpdate()
        })
    }
    
    private func resetStateFromServer() {
        if self.isLoadingMore {
            self.shouldResetStateFromServer = true
            return
        }
        
        self.isLoadingMore = true
        
        self.updateQueue.removeAll()
        
        self.disposable.set((getGroupCallParticipants(account: self.account, callId: self.id, accessHash: self.accessHash, offset: "", ssrcs: [], limit: 100, sortAscending: self.stateValue.state.sortAscending)
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isLoadingMore = false
            strongSelf.shouldResetStateFromServer = false
            var state = state
            state.mergeActivity(from: strongSelf.stateValue.state, myPeerId: nil, previousMyPeerId: nil, mergeActivityTimestamps: false)
            strongSelf.stateValue.state = state
            strongSelf.endedProcessingUpdate()
        }))
    }
    
    public func updateMuteState(peerId: PeerId, muteState: Participant.MuteState?, volume: Int32?, raiseHand: Bool?) {
        if let current = self.stateValue.overlayState.pendingMuteStateChanges[peerId] {
            if current.state == muteState {
                return
            }
            current.disposable.dispose()
            self.stateValue.overlayState.pendingMuteStateChanges.removeValue(forKey: peerId)
        }
        
        for participant in self.stateValue.state.participants {
            if participant.peer.id == peerId {
                var raiseHandEqual: Bool = true
                if let raiseHand = raiseHand {
                    raiseHandEqual = (participant.raiseHandRating == nil && !raiseHand) ||
                        (participant.raiseHandRating != nil && raiseHand)
                }
                if participant.muteState == muteState && participant.volume == volume && raiseHandEqual {
                    return
                }
            }
        }
        
        let disposable = MetaDisposable()
        if raiseHand == nil {
            self.stateValue.overlayState.pendingMuteStateChanges[peerId] = OverlayState.MuteStateChange(
                state: muteState,
                volume: volume,
                disposable: disposable
            )
        }
        
        let account = self.account
        let id = self.id
        let accessHash = self.accessHash
        let myPeerId = self.myPeerId
        
        let signal: Signal<Api.Updates?, NoError> = self.account.postbox.transaction { transaction -> Api.InputPeer? in
            return transaction.getPeer(peerId).flatMap(apiInputPeer)
        }
        |> mapToSignal { inputPeer -> Signal<Api.Updates?, NoError> in
            guard let inputPeer = inputPeer else {
                return .single(nil)
            }
            var flags: Int32 = 0
            if let volume = volume, volume > 0 {
                flags |= 1 << 1
            }
            if let muteState = muteState, (!muteState.canUnmute || peerId == myPeerId || muteState.mutedByYou) {
                flags |= 1 << 0
            }
            let raiseHandApi: Api.Bool?
            if let raiseHand = raiseHand {
                flags |= 1 << 2
                raiseHandApi = raiseHand ? .boolTrue : .boolFalse
            } else {
                raiseHandApi = nil
            }
                        
            return account.network.request(Api.functions.phone.editGroupCallParticipant(flags: flags, call: .inputGroupCall(id: id, accessHash: accessHash), participant: inputPeer, volume: volume, raiseHand: raiseHandApi))
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.Updates?, NoError> in
                return .single(nil)
            }
        }
        
        disposable.set((signal
        |> deliverOnMainQueue).start(next: { [weak self] updates in
            guard let strongSelf = self else {
                return
            }
            
            if let updates = updates {
                var stateUpdates: [GroupCallParticipantsContext.Update] = []
                
                loop: for update in updates.allUpdates {
                    switch update {
                    case let .updateGroupCallParticipants(call, participants, version):
                        switch call {
                        case let .inputGroupCall(updateCallId, _):
                            if updateCallId != id {
                                continue loop
                            }
                        }
                        stateUpdates.append(.state(update: GroupCallParticipantsContext.Update.StateUpdate(participants: participants, version: version, removePendingMuteStates: [peerId])))
                    default:
                        break
                    }
                }
                
                strongSelf.addUpdates(updates: stateUpdates)
                
                strongSelf.account.stateManager.addUpdates(updates)
            } else {
                strongSelf.stateValue.overlayState.pendingMuteStateChanges.removeValue(forKey: peerId)
            }
        }))
    }
    
    public func raiseHand() {
        self.updateMuteState(peerId: self.myPeerId, muteState: nil, volume: nil, raiseHand: true)
    }
    
    public func lowerHand() {
        self.updateMuteState(peerId: self.myPeerId, muteState: nil, volume: nil, raiseHand: false)
    }
    
    public func updateShouldBeRecording(_ shouldBeRecording: Bool, title: String?) {
        var flags: Int32 = 0
        if shouldBeRecording {
            flags |= 1 << 0
        }
        if let title = title, !title.isEmpty {
            flags |= (1 << 1)
        }
        self.updateShouldBeRecordingDisposable.set((self.account.network.request(Api.functions.phone.toggleGroupCallRecord(flags: flags, call: .inputGroupCall(id: self.id, accessHash: self.accessHash), title: title))
        |> deliverOnMainQueue).start(next: { [weak self] updates in
            guard let strongSelf = self else {
                return
            }
            strongSelf.account.stateManager.addUpdates(updates)
        }))
    }
    
    public func updateDefaultParticipantsAreMuted(isMuted: Bool) {
        if isMuted == self.stateValue.state.defaultParticipantsAreMuted.isMuted {
            return
        }
        self.stateValue.state.defaultParticipantsAreMuted.isMuted = isMuted
        
        self.updateDefaultMuteDisposable.set((self.account.network.request(Api.functions.phone.toggleGroupCallSettings(flags: 1 << 0, call: .inputGroupCall(id: self.id, accessHash: self.accessHash), joinMuted: isMuted ? .boolTrue : .boolFalse))
        |> deliverOnMainQueue).start(next: { [weak self] updates in
            guard let strongSelf = self else {
                return
            }
            strongSelf.account.stateManager.addUpdates(updates)
        }))
    }
    
    public func resetInviteLinks() {
        self.resetInviteLinksDisposable.set((self.account.network.request(Api.functions.phone.toggleGroupCallSettings(flags: 1 << 1, call: .inputGroupCall(id: self.id, accessHash: self.accessHash), joinMuted: nil))
        |> deliverOnMainQueue).start(next: { [weak self] updates in
            guard let strongSelf = self else {
                return
            }
            strongSelf.account.stateManager.addUpdates(updates)
        }))
    }
    
    public func loadMore(token: String) {
        if token != self.stateValue.state.nextParticipantsFetchOffset {
            Logger.shared.log("GroupCallParticipantsContext", "loadMore called with an invalid token \(token) (the valid one is \(String(describing: self.stateValue.state.nextParticipantsFetchOffset)))")
            return
        }
        if self.isLoadingMore {
            return
        }
        self.isLoadingMore = true
        
        self.disposable.set((getGroupCallParticipants(account: self.account, callId: self.id, accessHash: self.accessHash, offset: token, ssrcs: [], limit: 100, sortAscending: self.stateValue.state.sortAscending)
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isLoadingMore = false
            
            var updatedState = strongSelf.stateValue.state
            
            updatedState.participants = mergeAndSortParticipants(current: updatedState.participants, with: state.participants, sortAscending: updatedState.sortAscending)
            
            updatedState.nextParticipantsFetchOffset = state.nextParticipantsFetchOffset
            updatedState.totalCount = max(updatedState.totalCount, state.totalCount)
            updatedState.version = max(updatedState.version, updatedState.version)
            
            strongSelf.stateValue.state = updatedState
            
            if strongSelf.shouldResetStateFromServer {
                strongSelf.resetStateFromServer()
            }
        }))
    }
}

extension GroupCallParticipantsContext.Update.StateUpdate.ParticipantUpdate {
    init(_ apiParticipant: Api.GroupCallParticipant) {
        switch apiParticipant {
        case let .groupCallParticipant(flags, apiPeerId, date, activeDate, source, volume, about, raiseHandRating):
            let peerId: PeerId
            switch apiPeerId {
                case let .peerUser(userId):
                    peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                case let .peerChat(chatId):
                    peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                case let .peerChannel(channelId):
                    peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
            }
            let ssrc = UInt32(bitPattern: source)
            let muted = (flags & (1 << 0)) != 0
            let mutedByYou = (flags & (1 << 9)) != 0
            var muteState: GroupCallParticipantsContext.Participant.MuteState?
            if muted {
                let canUnmute = (flags & (1 << 2)) != 0
                muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: canUnmute, mutedByYou: mutedByYou)
            } else if mutedByYou {
                muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: false, mutedByYou: mutedByYou)
            }
            let isRemoved = (flags & (1 << 1)) != 0
            let justJoined = (flags & (1 << 4)) != 0
            let isMin = (flags & (1 << 8)) != 0
            
            let participationStatusChange: GroupCallParticipantsContext.Update.StateUpdate.ParticipantUpdate.ParticipationStatusChange
            if isRemoved {
                participationStatusChange = .left
            } else if justJoined {
                participationStatusChange = .joined
            } else {
                participationStatusChange = .none
            }
            
            let jsonParams: String? = nil
            /*if let params = params {
                switch params {
                case let .dataJSON(data):
                    jsonParams = data
                }
            }*/
            
            self.init(
                peerId: peerId,
                ssrc: ssrc,
                jsonParams: jsonParams,
                joinTimestamp: date,
                activityTimestamp: activeDate.flatMap(Double.init),
                raiseHandRating: raiseHandRating,
                muteState: muteState,
                participationStatusChange: participationStatusChange,
                volume: volume,
                about: about,
                isMin: isMin
            )
        }
    }
}

extension GroupCallParticipantsContext.Update.StateUpdate {
    init(participants: [Api.GroupCallParticipant], version: Int32, removePendingMuteStates: Set<PeerId> = Set()) {
        var participantUpdates: [GroupCallParticipantsContext.Update.StateUpdate.ParticipantUpdate] = []
        for participant in participants {
            switch participant {
            case let .groupCallParticipant(flags, apiPeerId, date, activeDate, source, volume, about, raiseHandRating):
                let peerId: PeerId
                switch apiPeerId {
                    case let .peerUser(userId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: userId)
                    case let .peerChat(chatId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudGroup, id: chatId)
                    case let .peerChannel(channelId):
                        peerId = PeerId(namespace: Namespaces.Peer.CloudChannel, id: channelId)
                }
                let ssrc = UInt32(bitPattern: source)
                let muted = (flags & (1 << 0)) != 0
                let mutedByYou = (flags & (1 << 9)) != 0
                var muteState: GroupCallParticipantsContext.Participant.MuteState?
                if muted {
                    let canUnmute = (flags & (1 << 2)) != 0
                    muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: canUnmute, mutedByYou: mutedByYou)
                } else if mutedByYou {
                    muteState = GroupCallParticipantsContext.Participant.MuteState(canUnmute: false, mutedByYou: mutedByYou)
                }
                let isRemoved = (flags & (1 << 1)) != 0
                let justJoined = (flags & (1 << 4)) != 0
                let isMin = (flags & (1 << 8)) != 0
                
                let participationStatusChange: GroupCallParticipantsContext.Update.StateUpdate.ParticipantUpdate.ParticipationStatusChange
                if isRemoved {
                    participationStatusChange = .left
                } else if justJoined {
                    participationStatusChange = .joined
                } else {
                    participationStatusChange = .none
                }
                
                let jsonParams: String? = nil
                /*if let params = params {
                    switch params {
                    case let .dataJSON(data):
                        jsonParams = data
                    }
                }*/
                
                participantUpdates.append(GroupCallParticipantsContext.Update.StateUpdate.ParticipantUpdate(
                    peerId: peerId,
                    ssrc: ssrc,
                    jsonParams: jsonParams,
                    joinTimestamp: date,
                    activityTimestamp: activeDate.flatMap(Double.init),
                    raiseHandRating: raiseHandRating,
                    muteState: muteState,
                    participationStatusChange: participationStatusChange,
                    volume: volume,
                    about: about,
                    isMin: isMin
                ))
            }
        }
        
        self.init(
            participantUpdates: participantUpdates,
            version: version,
            removePendingMuteStates: removePendingMuteStates
        )
    }
}

public enum InviteToGroupCallError {
    case generic
}

public func inviteToGroupCall(account: Account, callId: Int64, accessHash: Int64, peerId: PeerId) -> Signal<Never, InviteToGroupCallError> {
    return account.postbox.transaction { transaction -> Peer? in
        return transaction.getPeer(peerId)
    }
    |> castError(InviteToGroupCallError.self)
    |> mapToSignal { user -> Signal<Never, InviteToGroupCallError> in
        guard let user = user else {
            return .fail(.generic)
        }
        guard let apiUser = apiInputUser(user) else {
            return .fail(.generic)
        }
        
        return account.network.request(Api.functions.phone.inviteToGroupCall(call: .inputGroupCall(id: callId, accessHash: accessHash), users: [apiUser]))
        |> mapError { _ -> InviteToGroupCallError in
            return .generic
        }
        |> mapToSignal { result -> Signal<Never, InviteToGroupCallError> in
            account.stateManager.addUpdates(result)
            
            return .complete()
        }
    }
}

public struct GroupCallInviteLinks {
    public let listenerLink: String
    public let speakerLink: String?
    
    public init(listenerLink: String, speakerLink: String?) {
        self.listenerLink = listenerLink
        self.speakerLink = speakerLink
    }
}

public func groupCallInviteLinks(account: Account, callId: Int64, accessHash: Int64) -> Signal<GroupCallInviteLinks?, NoError> {
    let call = Api.InputGroupCall.inputGroupCall(id: callId, accessHash: accessHash)
    let listenerInvite: Signal<String?, NoError> = account.network.request(Api.functions.phone.exportGroupCallInvite(flags: 0, call: call))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.phone.ExportedGroupCallInvite?, NoError> in
        return .single(nil)
    }
    |> mapToSignal { result -> Signal<String?, NoError> in
        if let result = result,  case let .exportedGroupCallInvite(link) = result {
            return .single(link)
        }
        return .single(nil)
    }

    let speakerInvite: Signal<String?, NoError> = account.network.request(Api.functions.phone.exportGroupCallInvite(flags: 1 << 0, call: call))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.phone.ExportedGroupCallInvite?, NoError> in
        return .single(nil)
    }
    |> mapToSignal { result -> Signal<String?, NoError> in
        if let result = result,  case let .exportedGroupCallInvite(link) = result {
            return .single(link)
        }
        return .single(nil)
    }
    
    return combineLatest(listenerInvite, speakerInvite)
    |> map { listenerLink, speakerLink in
        if let listenerLink = listenerLink {
            return GroupCallInviteLinks(listenerLink: listenerLink, speakerLink: speakerLink)
        } else {
            return nil
        }
    }
}

public enum EditGroupCallTitleError {
    case generic
}

public func editGroupCallTitle(account: Account, callId: Int64, accessHash: Int64, title: String) -> Signal<Never, EditGroupCallTitleError> {
    return account.network.request(Api.functions.phone.editGroupCallTitle(call: .inputGroupCall(id: callId, accessHash: accessHash), title: title)) |> mapError { _ -> EditGroupCallTitleError in
        return .generic
    }
    |> mapToSignal { result -> Signal<Never, EditGroupCallTitleError> in
        account.stateManager.addUpdates(result)
        return .complete()
    }
}

public func groupCallDisplayAsAvailablePeers(network: Network, postbox: Postbox, peerId: PeerId) -> Signal<[FoundPeer], NoError> {
    return postbox.transaction { transaction -> Api.InputPeer? in
        return transaction.getPeer(peerId).flatMap(apiInputPeer)
    } |> mapToSignal { inputPeer in
        guard let inputPeer = inputPeer else {
            return .complete()
        }
        return network.request(Api.functions.phone.getGroupCallJoinAs(peer: inputPeer))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.phone.JoinAsPeers?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { result in
            guard let result = result else {
                return .single([])
            }
            switch result {
            case let .joinAsPeers(_, chats, _):
                var subscribers: [PeerId: Int32] = [:]
                let peers = chats.compactMap(parseTelegramGroupOrChannel)
                for chat in chats {
                    if let groupOrChannel = parseTelegramGroupOrChannel(chat: chat) {
                        switch chat {
                        case let .channel(_, _, _, _, _, _, _, _, _, _, _, _, participantsCount):
                            if let participantsCount = participantsCount {
                                subscribers[groupOrChannel.id] = participantsCount
                            }
                        case let .chat(_, _, _, _, participantsCount, _, _, _, _, _):
                            subscribers[groupOrChannel.id] = participantsCount
                        default:
                            break
                        }
                    }
                }
                return postbox.transaction { transaction -> [Peer] in
                    updatePeers(transaction: transaction, peers: peers, update: { _, updated in
                        return updated
                    })
                    return peers
                } |> map { peers -> [FoundPeer] in
                    return peers.map { FoundPeer(peer: $0, subscribers: subscribers[$0.id]) }
                }
            }
        }
        
    }
}

public final class CachedDisplayAsPeers: PostboxCoding {
    public let peerIds: [PeerId]
    public let timestamp: Int32
    
    public init(peerIds: [PeerId], timestamp: Int32) {
        self.peerIds = peerIds
        self.timestamp = timestamp
    }
    
    public init(decoder: PostboxDecoder) {
        self.peerIds = decoder.decodeInt64ArrayForKey("peerIds").map { PeerId($0) }
        self.timestamp = decoder.decodeInt32ForKey("timestamp", orElse: 0)
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt64Array(self.peerIds.map { $0.toInt64() }, forKey: "peerIds")
        encoder.encodeInt32(self.timestamp, forKey: "timestamp")
    }
}


public func cachedGroupCallDisplayAsAvailablePeers(account: Account, peerId: PeerId) -> Signal<[FoundPeer], NoError> {
    let key = ValueBoxKey(length: 8)
    key.setInt64(0, value: peerId.toInt64())
    return account.postbox.transaction { transaction -> ([FoundPeer], Int32)? in
        let cached = transaction.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedGroupCallDisplayAsPeers, key: key)) as? CachedDisplayAsPeers
        if let cached = cached {
            var peers: [FoundPeer] = []
            for peerId in cached.peerIds {
                if let peer = transaction.getPeer(peerId) {
                    var subscribers: Int32?
                    if let cachedData = transaction.getPeerCachedData(peerId: peerId) as? CachedChannelData {
                        subscribers = cachedData.participantsSummary.memberCount
                    }
                    peers.append(FoundPeer(peer: peer, subscribers: subscribers))
                }
            }
            return (peers, cached.timestamp)
        } else {
            return nil
        }
    }
    |> mapToSignal { cachedPeersAndTimestamp -> Signal<[FoundPeer], NoError> in
        let currentTimestamp = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
        if let (cachedPeers, timestamp) = cachedPeersAndTimestamp, currentTimestamp - timestamp < 60 * 3 && !cachedPeers.isEmpty {
            return .single(cachedPeers)
        } else {
            return groupCallDisplayAsAvailablePeers(network: account.network, postbox: account.postbox, peerId: peerId)
            |> mapToSignal { peers -> Signal<[FoundPeer], NoError> in
                return account.postbox.transaction { transaction -> [FoundPeer] in
                    let currentTimestamp = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                    transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedGroupCallDisplayAsPeers, key: key), entry: CachedDisplayAsPeers(peerIds: peers.map { $0.peer.id }, timestamp: currentTimestamp), collectionSpec: ItemCacheCollectionSpec(lowWaterItemCount: 10, highWaterItemCount: 20))
                    return peers
                }
            }
        }
    }
}

public func updatedCurrentPeerGroupCall(account: Account, peerId: PeerId) -> Signal<CachedChannelData.ActiveCall?, NoError> {
    return fetchAndUpdateCachedPeerData(accountPeerId: account.peerId, peerId: peerId, network: account.network, postbox: account.postbox)
    |> mapToSignal { _ -> Signal<CachedChannelData.ActiveCall?, NoError> in
        return account.postbox.transaction { transaction -> CachedChannelData.ActiveCall? in
            return (transaction.getPeerCachedData(peerId: peerId) as? CachedChannelData)?.activeCall
        }
    }
}

private func mergeAndSortParticipants(current currentParticipants: [GroupCallParticipantsContext.Participant], with updatedParticipants: [GroupCallParticipantsContext.Participant], sortAscending: Bool) -> [GroupCallParticipantsContext.Participant] {
    var mergedParticipants = currentParticipants
    
    var existingParticipantIndices: [PeerId: Int] = [:]
    for i in 0 ..< mergedParticipants.count {
        existingParticipantIndices[mergedParticipants[i].peer.id] = i
    }
    for participant in updatedParticipants {
        if let _ = existingParticipantIndices[participant.peer.id] {
        } else {
            existingParticipantIndices[participant.peer.id] = mergedParticipants.count
            mergedParticipants.append(participant)
        }
    }

    mergedParticipants.sort(by: { GroupCallParticipantsContext.Participant.compare(lhs: $0, rhs: $1, sortAscending: sortAscending) })
    
    return mergedParticipants
}

public final class AudioBroadcastDataSource {
    fileprivate let download: Download
    
    fileprivate init(download: Download) {
        self.download = download
    }
}

public func getAudioBroadcastDataSource(account: Account, callId: Int64, accessHash: Int64) -> Signal<AudioBroadcastDataSource?, NoError> {
    return account.network.request(Api.functions.phone.getGroupCall(call: .inputGroupCall(id: callId, accessHash: accessHash)))
    |> map(Optional.init)
    |> `catch` { _ -> Signal<Api.phone.GroupCall?, NoError> in
        return .single(nil)
    }
    |> mapToSignal { result -> Signal<AudioBroadcastDataSource?, NoError> in
        guard let result = result else {
            return .single(nil)
        }
        switch result {
        case let .groupCall(call, _, _, _, _):
            if let datacenterId = GroupCallInfo(call)?.streamDcId.flatMap(Int.init) {
                return account.network.download(datacenterId: datacenterId, isMedia: true, tag: nil)
                |> map { download -> AudioBroadcastDataSource? in
                    return AudioBroadcastDataSource(download: download)
                }
            } else {
                return .single(nil)
            }
        }
    }
}

public struct GetAudioBroadcastPartResult {
    public enum Status {
        case data(Data)
        case notReady
        case resyncNeeded
        case rejoinNeeded
    }
    
    public var status: Status
    public var responseTimestamp: Double
}

public func getAudioBroadcastPart(dataSource: AudioBroadcastDataSource, callId: Int64, accessHash: Int64, timestampIdMilliseconds: Int64, durationMilliseconds: Int64) -> Signal<GetAudioBroadcastPartResult, NoError> {
    let scale: Int32
    switch durationMilliseconds {
    case 1000:
        scale = 0
    case 500:
        scale = 1
    default:
        return .single(GetAudioBroadcastPartResult(status: .notReady, responseTimestamp: Double(timestampIdMilliseconds) / 1000.0))
    }
    
    return dataSource.download.requestWithAdditionalData(Api.functions.upload.getFile(flags: 0, location: .inputGroupCallStream(call: .inputGroupCall(id: callId, accessHash: accessHash), timeMs: timestampIdMilliseconds, scale: scale), offset: 0, limit: 128 * 1024), automaticFloodWait: false, failOnServerErrors: true)
    |> map { result, responseTimestamp -> GetAudioBroadcastPartResult in
        switch result {
        case let .file(_, _, bytes):
            return GetAudioBroadcastPartResult(
                status: .data(bytes.makeData()),
                responseTimestamp: responseTimestamp
            )
        case .fileCdnRedirect:
            return GetAudioBroadcastPartResult(
                status: .notReady,
                responseTimestamp: responseTimestamp
            )
        }
    }
    |> `catch` { error, responseTimestamp -> Signal<GetAudioBroadcastPartResult, NoError> in
        if error.errorDescription == "GROUPCALL_JOIN_MISSING" {
            return .single(GetAudioBroadcastPartResult(
                status: .rejoinNeeded,
                responseTimestamp: responseTimestamp
            ))
        } else if error.errorDescription.hasPrefix("FLOOD_WAIT") || error.errorDescription == "TIME_TOO_BIG" {
            return .single(GetAudioBroadcastPartResult(
                status: .notReady,
                responseTimestamp: responseTimestamp
            ))
        } else if error.errorDescription == "TIME_INVALID" || error.errorDescription == "TIME_TOO_SMALL" {
            return .single(GetAudioBroadcastPartResult(
                status: .resyncNeeded,
                responseTimestamp: responseTimestamp
            ))
        } else {
            return .single(GetAudioBroadcastPartResult(
                status: .resyncNeeded,
                responseTimestamp: responseTimestamp
            ))
        }
    }
}
