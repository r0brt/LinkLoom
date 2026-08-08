import GRDB
import LinkLoomCore

enum TestDatabase {
    static func make() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrate(queue)
        return queue
    }
}
