//
//  File.swift
//  
//
//  Created by 周椿杰 on 2023/4/19.
//

import Foundation

class ServerSentEventsHandler: NSObject {

    var onEventReceived: ((Result<OpenAI<StreamMessageResult>, OpenAIError>) -> Void)?
    var onComplete: (() -> Void)?

    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionDataTask?
    private var cacheBuffer = [String]()

    func connect(with request: URLRequest) {
        task = session.dataTask(with: request)
        task?.resume()
    }

    func disconnect() {
        task?.cancel()
    }

    func processEvent(_ eventData: Data) {
        do {
            if let chatErr = try? JSONDecoder().decode(ChatError.self, from: eventData) as ChatError {
                onEventReceived?(.failure(.chatError(error: chatErr.error)))
                return
            }
            
            let res = try JSONDecoder().decode(OpenAI<StreamMessageResult>.self, from: eventData)
            onEventReceived?(.success(res))
        } catch {
            onEventReceived?(.failure(.decodingError(error: error)))
        }
    }
    
    // Identify full json
    func isFullJson(_ jsonString: String) -> Bool {
        if jsonString.isEmpty || (!jsonString.hasPrefix("{") && !jsonString.hasSuffix("}")) {
            return false
        }

        var bracesCount = 0
        
        for character in jsonString {
            if character == "{" {
                bracesCount += 1
            } else if character == "}" {
                bracesCount -= 1
            }
        }
        
        return bracesCount == 0
    }
}

extension ServerSentEventsHandler: URLSessionDataDelegate {

    /// It will be called several times, each time could return one chunk of data or multiple chunk of data
    /// The JSON look liks this:
    /// `data: {"id":"chatcmpl-6yVTvD6UAXsE9uG2SmW4Tc2iuFnnT","object":"chat.completion.chunk","created":1679878715,"model":"gpt-3.5-turbo-0301","choices":[{"delta":{"role":"assistant"},"index":0,"finish_reason":null}]}`
    /// `data: {"id":"chatcmpl-6yVTvD6UAXsE9uG2SmW4Tc2iuFnnT","object":"chat.completion.chunk","created":1679878715,"model":"gpt-3.5-turbo-0301","choices":[{"delta":{"content":"Once"},"index":0,"finish_reason":null}]}`
    /// The erroe JSON look like this:
    /// {
    ///     "error": {
    ///         "message": "Rate limit reached for default-gpt-3.5-turbo in organization org-lPcJIJx90ZmUZfVQ59mquulx on requests per min. Limit: 3 / min. Please try again in 20s. Contact support@openai.com if you continue to have issues. Please add a payment method to your account to increase your rate limit. Visit https://platform.openai.com/account/billing to add a payment method.",
    ///         "type": "requests",
    ///         "param": null,
    ///         "code": null
    ///     }
    /// }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let eventString = String(data: data, encoding: .utf8) {
            let lines = eventString.split(separator: "\n")
            for line in lines {
                if line == "data: [DONE]" {
                    cacheBuffer.removeAll()
                    return
                }
                if line.hasPrefix("data:"){
                    let jsonData = String(line.dropFirst(5))
                    if isFullJson(jsonData) {
                        if let eventData = jsonData.data(using: .utf8) {
                            processEvent(eventData)
                        }
                        cacheBuffer.removeAll()
                    } else {
                        cacheBuffer.append(jsonData)
                    }
                } else {
                    let unknownData = String(line)
                    if unknownData.isEmpty {
                        continue
                    }
                    if isFullJson(unknownData) {
                        if let eventData = unknownData.data(using: .utf8) {
                            processEvent(eventData)
                        }
                        cacheBuffer.removeAll()
                    } else {
                        // partial json data
                        var jsonData = ""
                        for bufferData in cacheBuffer {
                            jsonData.append(bufferData)
                        }
                        jsonData.append(unknownData)
                        if isFullJson(jsonData) {
                            if let eventData = jsonData.data(using: .utf8) {
                                processEvent(eventData)
                            }
                            cacheBuffer.removeAll()
                        } else {
                            cacheBuffer.append(unknownData)
                        }
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        cacheBuffer.removeAll()
        
        if let error = error {
            onEventReceived?(.failure(.genericError(error: error)))
        } else {
            onComplete?()
        }
    }
}
