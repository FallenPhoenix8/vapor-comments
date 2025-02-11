import Fluent
import JWT
import Vapor

let fileManager: FileManager = .init()
let wsManagerComments: WebSocketManager = .init(threadLabel: "wsManagerComments")

func routes(_ app: Application) throws {
    app.get("api", "comments") { req throws -> Response in
        if !fileManager.fileExists(atPath: "Sources/comments.json") {
            _ = fileManager.createFile(atPath: "Sources/comments.json", contents: "[]".data(using: String.Encoding.utf8))
        }

        let res = req.fileio.streamFile(at: "Sources/comments.json")
        return res
    }

    app.delete("api", "delete-comment") { req async throws -> Response in
        var comments: [Comment] = []
        do {
            let id = try req.query.get(Double.self, at: "id")
            let comment = try Comment(id: id)
            comments = try await comment.delete()
        } catch let err {
            _ = Abort(.internalServerError, reason: "Error deleting comment: \(err)")
        }

        do {
            try wsManagerComments.broadcast(JSONEncoder().encode(comments))
        } catch {
            _ = Abort(.badRequest, reason: "Invalid JSON data")
        }

        return req.fileio.streamFile(at: "Sources/comments.json")
    }

    app.post("api", "add-comment") { req async throws -> Response in
        let content = try req.query.get(String.self, at: "content")

        let comment = Comment(content: content)
        let comments = try await comment.add()

        try wsManagerComments.broadcast(JSONEncoder().encode(comments))

        return req.fileio.streamFile(at: "Sources/comments.json")
    }

    app.webSocket("ws", "comments") { _, ws in
        wsManagerComments.addConnection(ws)
    }

    app.post("auth", "register") { req async throws -> User in
        try User.Create.validate(content: req)
        let create = try req.content.decode(User.Create.self)

        guard create.password == create.confirmPassword else {
            throw Abort(.badRequest, reason: "Passwords do not match")
        }

        let user = try User(username: create.username, passwordHash: Bcrypt.hash(create.password))
        try await user.save(on: req.db)

        return user
    }

    app.post("auth", "login") { req async throws -> [String: String] in
        let loginData = try req.content.decode(User.Login.self)
        let expiration = Date().addingTimeInterval(60 * 60 * 24 * 7 /* 7 days */ )

        guard let user = try await User.query(on: req.db).filter(\.$username == loginData.username).first() else {
            throw Abort(.unauthorized, reason: "User not found")
        }

        guard try user.verify(password: loginData.password) else {
            throw Abort(.unauthorized, reason: "Incorrect password")
        }

        let payload = User.Payload(
            subject: SubjectClaim(value: user.id!.uuidString),
            expiration: .init(value: expiration)
        )
        let token = try await req.jwt.sign(payload)

        return ["token": token]
    }

    app.get("auth", "me") { req async throws -> HTTPStatus in
        let payload = try await req.jwt.verify(as: User.Payload.self)
        print(payload)
        return .ok
    }
}
