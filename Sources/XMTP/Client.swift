//
//  Client.swift
//
//
//  Created by Pat Nakajima on 11/22/22.
//

import Foundation

struct ClientOptions {
	struct Api {
		var env: Environment = .production
		var isSecure: Bool = true
	}

	var api = Api()
}

class Client {
	var address: String
	var privateKeyBundleV1: PrivateKeyBundleV1
	var apiClient: ApiClient

	public static func create(account: SigningKey, options: ClientOptions = ClientOptions()) async throws -> Client {
		let apiClient = try ApiClient(
			environment: options.api.env,
			secure: options.api.isSecure
		)

		let privateKeyBundleV1 = try await loadOrCreateKeys(for: account, apiClient: apiClient)

		return try Client(address: account.address, privateKeyBundleV1: privateKeyBundleV1, apiClient: apiClient)
	}

	static func loadOrCreateKeys(for account: SigningKey, apiClient: ApiClient) async throws -> PrivateKeyBundleV1 {
		// swiftlint:disable no_optional_try
		if let keys = try? await loadPrivateKeys(for: account, apiClient: apiClient) {
			// swiftlint:enable no_optional_try
			return keys
		} else {
			return try await PrivateKeyBundleV1.generate(wallet: account)
		}
	}

	static func loadPrivateKeys(for account: SigningKey, apiClient: ApiClient) async throws -> PrivateKeyBundleV1? {
		let topics: [Topic] = [.userPrivateStoreKeyBundle(account.address)]
		let res = try await apiClient.query(topics: topics)

		for envelope in res.envelopes {
			do {
				let encryptedBundle = try EncryptedPrivateKeyBundle(serializedData: envelope.message)
				let bundle = try await encryptedBundle.decrypted(with: account)

				return bundle.v1
			} catch {
				print("Error decoding encrypted private key bundle: \(error)")
				continue
			}
		}

		return nil
	}

	init(address: String, privateKeyBundleV1: PrivateKeyBundleV1, apiClient: ApiClient) throws {
		self.address = address
		self.privateKeyBundleV1 = privateKeyBundleV1
		self.apiClient = apiClient
	}

	func publishUserContact() async throws {
		var keyBundle = privateKeyBundleV1.toPublicKeyBundle()
		var contactBundle = ContactBundle()
		contactBundle.v1.keyBundle = keyBundle

		var envelope = Envelope()
		envelope.contentTopic = Topic.contact(address).description
		envelope.timestampNs = UInt64(Date().millisecondsSinceEpoch * 1_000_000)
		envelope.message = try contactBundle.serializedData()

		_ = try await publish(envelopes: [envelope])
	}

	func publish(envelopes: [Envelope]) async throws -> PublishResponse {
		let authorized = AuthorizedIdentity(address: address, authorized: privateKeyBundleV1.identityKey.publicKey, identity: privateKeyBundleV1.identityKey)
		let authToken = try await authorized.createAuthToken()

		apiClient.setAuthToken(authToken)

		return try await apiClient.publish(envelopes: envelopes)
	}

	func getUserContact(peerAddress: String) async throws -> ContactBundle? {
		let response = try await apiClient.query(topics: [.contact(peerAddress)])

		for envelope in response.envelopes {
			// swiftlint:disable no_optional_try
			if let contactBundle = try? ContactBundle.from(envelope: envelope) {
				return contactBundle
			}
			// swiftlint:enable no_optional_try
		}

		return nil
	}
}