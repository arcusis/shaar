// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarAPIOperationTests {
  @Test func graphQLPostNamesTheOperationAndIgnoresVariables() {
    let body = """
      {"query":"query GetUser { user { id } }","operationName":"GetUser","variables":{"secret":"do-not-keep"}}
      """
    let operation = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql", body: body, responseBody: nil)
    #expect(operation?.columnText == "GetUser · query")
    #expect(operation?.hasErrors == false)
    #expect(operation?.columnText.contains("do-not-keep") == false)
  }

  @Test func operationNameSelectsTheMatchingCallType() {
    let body = """
      {"operationName":"Update","query":"query GetUser { user { id } } mutation Update { ok }"}
      """
    let operation = ShaarAPIOperation.parse(
      method: "POST", url: "https://api.example.com/data", body: body, responseBody: nil)
    #expect(operation?.name == "Update")
    #expect(operation?.callType == .mutation)
  }

  @Test func persistedQueryWithoutADocumentUsesTheOperationName() {
    let body = """
      {"operationName":"GetUser","extensions":{"persistedQuery":{"version":1,"sha256Hash":"abc"}}}
      """
    let operation = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/api", body: body, responseBody: nil)
    #expect(operation?.columnText == "GetUser · graphql")
    #expect(operation?.callType == .unknown)
  }

  @Test func anonymousShorthandIsAQuery() {
    let operation = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql", body: "{ hello }", responseBody: nil)
    #expect(operation?.columnText == "anonymous · query")
  }

  @Test func commentsAndStringsDoNotInventAnOperation() {
    let body = """
      {"query":"# query Hidden\\nquery GetUser { field(arg: \\"query Hidden\\") }"}
      """
    let operation = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql", body: body, responseBody: nil)
    #expect(operation?.columnText == "GetUser · query")
  }

  @Test func mixedBatchUsesTheFirstCallType() {
    let body = """
      [{"query":"query Alpha { a }"},{"query":"mutation Beta { b }"}]
      """
    let operation = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql", body: body, responseBody: nil)
    #expect(operation?.name == "Alpha, Beta")
    #expect(operation?.callType == .query)
  }

  @Test func formBodyCarriesTheOperation() {
    let operation = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql",
      body: "operationName=Ping&query=query+Ping+%7B+__typename+%7D", responseBody: nil)
    #expect(operation?.columnText == "Ping · query")
  }

  @Test func graphQLGetReadsOperationNameFromTheURL() {
    let operation = ShaarAPIOperation.parse(
      method: "GET",
      url: "https://example.com/graphql?operationName=Continents&query=query%20Continents",
      body: nil, responseBody: nil)
    #expect(operation?.columnText == "Continents · query")
  }

  @Test func graphQLPathAloneIsNotAnOperation() {
    let operation = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql", body: nil, responseBody: nil)
    #expect(operation == nil)
  }

  @Test func ordinaryJSONPostIsNotGraphQL() {
    let operation = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/api", body: "{\"name\":\"hello\"}",
      responseBody: nil)
    #expect(operation == nil)
  }

  @Test func trpcNamesComeFromTheURL() {
    let list = ShaarAPIOperation.parse(
      method: "GET", url: "https://example.com/api/trpc/post.list?batch=1", body: nil,
      responseBody: nil)
    let root = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/trpc/proc", body: nil, responseBody: nil)
    let versioned = ShaarAPIOperation.parse(
      method: "GET", url: "https://example.com/v1/api/trpc/post.list", body: nil,
      responseBody: nil)
    let batch = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/api/trpc/post.list,post.byId", body: nil,
      responseBody: nil)
    #expect(list?.columnText == "post.list · query")
    #expect(root?.columnText == "proc · mutation")
    #expect(versioned?.name == "post.list")
    #expect(batch?.name == "post.list, post.byId")
    #expect(batch?.callType == .mutation)
  }

  @Test func blogPathIsNotTrpcUnlessTheNameLooksLikeAProcedure() {
    let article = ShaarAPIOperation.parse(
      method: "GET", url: "https://example.com/blog/trpc/intro", body: nil, responseBody: nil)
    let procedure = ShaarAPIOperation.parse(
      method: "GET", url: "https://example.com/blog/trpc/post.list", body: nil, responseBody: nil)
    #expect(article == nil)
    #expect(procedure?.name == "post.list")
  }

  @Test func graphQLErrorsMarkHTTP200AndEmptyErrorsDoNot() {
    let failed = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql",
      body: "{\"query\":\"query GetUser { user { id } }\"}",
      responseBody: "{\"data\":null,\"errors\":[{\"message\":\"no\"}]}")
    let empty = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql",
      body: "{\"query\":\"query GetUser { user { id } }\"}",
      responseBody: "{\"data\":{},\"errors\":[]}")
    let nested = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql",
      body: "{\"query\":\"query GetUser { user { id } }\"}",
      responseBody: "{\"data\":{\"error\":\"nope\"}}")
    let broken = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/graphql",
      body: "{\"query\":\"query GetUser { user { id } }\"}",
      responseBody: "not-json")
    #expect(failed?.hasErrors == true)
    #expect(empty?.hasErrors == false)
    #expect(nested?.hasErrors == false)
    #expect(broken?.hasErrors == false)
  }

  @Test func trpcErrorObjectIsRedAndResultDataIsNot() {
    let failed = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/api/trpc/post.create", body: "{}",
      responseBody: "{\"error\":{\"json\":{\"message\":\"nope\"}}}")
    let batch = ShaarAPIOperation.parse(
      method: "POST", url: "https://example.com/api/trpc/post.create", body: "{}",
      responseBody: "[{\"error\":{\"json\":{\"message\":\"nope\"}}}]")
    let ok = ShaarAPIOperation.parse(
      method: "GET", url: "https://example.com/api/trpc/post.list", body: nil,
      responseBody: "{\"result\":{\"data\":{\"ok\":true}}}")
    #expect(failed?.hasErrors == true)
    #expect(batch?.hasErrors == true)
    #expect(ok?.hasErrors == false)
  }

  @Test func filterAndSearchUseTheOperation() {
    let model = ShaarNetworkModel()
    let events = [
      request("POST", "https://example.com/graphql", id: "g", payload: graphQL("GetUser")),
      request("GET", "https://example.com/app.js", id: "js"),
      request(
        "POST", "https://example.com/graphql", id: "bad", payload: graphQL("UpdateUser"),
        response: "{\"errors\":[{\"message\":\"no\"}]}"),
    ]
    model.filter = .api
    let api = model.visibleRequests(from: events)
    #expect(api.map(\.apiOperation?.name) == ["GetUser", "UpdateUser"])
    model.search = "UpdateUser"
    #expect(model.visibleRequests(from: events).map(\.apiOperation?.name) == ["UpdateUser"])
    model.search = ""
    model.filter = .errors
    let errors = model.visibleRequests(from: events)
    #expect(errors.map(\.apiOperation?.name) == ["UpdateUser"])
    #expect(errors[0].isError == false)
    #expect(model.agentCopyText(for: errors[0]).contains("Operation: UpdateUser · query"))
    #expect(model.agentCopyText(for: errors[0]).contains("Response has errors"))
  }

  @Test func observationsMatchInOrderAndSkipPreflight() {
    let model = ShaarNetworkModel()
    let url = "https://example.com/graphql"
    model.replaceAPIObservations([
      observation("POST", url, body: graphQL("GetUser"), id: 1),
      observation("POST", url, body: graphQL("UpdateUser"), id: 2),
    ])
    let events = [
      request("POST", url, id: "1"),
      request("OPTIONS", url, id: "preflight"),
      request("POST", url, id: "2"),
    ]
    let rows = model.visibleRequests(from: events)
    #expect(rows.map(\.apiOperation?.name) == ["GetUser", nil, "UpdateUser"])
  }

  @Test func observedBodyWinsForPostAndResponseErrorsStillApply() {
    let model = ShaarNetworkModel()
    let url = "https://example.com/api/query"
    model.replaceAPIObservations([
      observation("POST", url, body: graphQL("GetUser"), errors: true, id: 4)
    ])
    let events = [
      request("POST", url, id: "1", payload: graphQL("Other"), response: "{\"data\":{}}")
    ]
    let row = model.visibleRequests(from: events)[0]
    #expect(row.apiOperation?.name == "GetUser")
    #expect(row.apiOperation?.hasErrors == true)
  }

  @Test func clearedLogIgnoresObservationsAlreadySeen() {
    let model = ShaarNetworkModel()
    let url = "https://example.com/graphql"
    model.replaceAPIObservations([observation("POST", url, body: graphQL("GetUser"), id: 3)])
    let first = model.visibleRequests(from: [request("POST", url, id: "1")])
    #expect(first.first?.apiOperation?.name == "GetUser")
    model.resetLog()
    model.replaceAPIObservations([observation("POST", url, body: graphQL("GetUser"), id: 3)])
    let ignored = model.visibleRequests(from: [request("POST", url, id: "2")])
    #expect(ignored.first?.apiOperation == nil)
    model.replaceAPIObservations([observation("POST", url, body: graphQL("GetUser"), id: 4)])
    let next = model.visibleRequests(from: [request("POST", url, id: "3")])
    #expect(next.first?.apiOperation?.name == "GetUser")
  }

  @Test func snapshotJSONBecomesObservations() {
    let raw = """
      [{"install":"abc","id":2,"method":"POST","url":"https://example.com/graphql","postData":null,"responseHasErrors":true}]
      """
    let observations = ShaarAPIObservation.list(from: raw)
    #expect(observations.count == 1)
    #expect(observations[0].postData == nil)
    #expect(observations[0].responseHasErrors == true)
  }

  @Test func pageScriptKeepsTheOperationGlobalAndDropsVariables() {
    let source = ShaarAPIOperationScript.source
    #expect(source.contains("__shaarAPIOperations"))
    #expect(source.contains("snapshot"))
    #expect(source.contains("dispose"))
    #expect(source.contains("persistedQuery: {}"))
    #expect(!source.contains("variables"))
    #expect(!source.contains("sha256Hash"))
    #expect(!source.contains("console.log"))
  }
}

private func graphQL(_ name: String) -> String {
  "{\"query\":\"query \(name) { user { id } }\",\"operationName\":\"\(name)\"}"
}

private func request(
  _ method: String, _ url: String, status: Int = 200, id: String,
  payload: String? = nil, response: String? = nil
) -> ShaarDevToolsEvent {
  .network(
    .init(
      id: UUID(), method: method, url: url, status: status, requestID: id,
      payload: payload, responseBody: response))
}

private func observation(
  _ method: String, _ url: String, body: String?, errors: Bool = false, id: Int,
  install: String = "test"
) -> ShaarAPIObservation {
  ShaarAPIObservation(
    install: install, id: id, method: method, url: url, postData: body,
    responseHasErrors: errors)
}
