import Foundation

/// A listing of this user's processes, one to a line, as `ps` prints it.
///
/// On a busy Mac it runs to half a megabyte, and whoever reads it is looking for the two or three lines of one client's
/// own service. Those lines are found by searching the listing's bytes; only they become strings for the reader to
/// take apart.
enum ProcessLines {
    /// The lines that contain one of `words`, in the listing's order. Letters match whatever their case; the words are
    /// plain ASCII without a line break.
    static func mentioning(_ words: [String], in listing: String) -> [String] {
        let words = words.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return listing.withCString { text in
            let length = strlen(text)
            // Each line that holds a match, by where it starts.
            var found: [Int: Int] = [:]
            for word in words {
                var cursor = 0
                // The words are ASCII, and no locale folds another byte into an ASCII letter.
                while cursor < length, let match = strcasestr(text + cursor, word) {
                    var start = text.distance(to: match)
                    while start > 0, text[start - 1] != 0x0A { start -= 1 }
                    let end = memchr(match, 0x0A, length - text.distance(to: match))
                        .map { UnsafeRawPointer(text).distance(to: $0) } ?? length
                    found[start] = end
                    cursor = end + 1
                }
            }
            return found.sorted { $0.key < $1.key }.map { start, end in
                String(decoding: UnsafeRawBufferPointer(start: text + start, count: end - start), as: UTF8.self)
            }
        }
    }
}
