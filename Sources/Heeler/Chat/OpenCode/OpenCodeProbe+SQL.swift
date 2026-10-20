import Foundation

/// The SQL behind each query (ADR 0025). Every statement reads one session
/// from `session_v2`, `session_message`, `event_sequence` or
/// `session_inbox`, and nothing writes. The statements stay within SQLite
/// 3.25 with JSON1: window functions and `pragma_table_info` are fine, while
/// `->`, `iif`, `FILTER`, `NULLS FIRST`, `HAVING` without `GROUP BY` and
/// `ORDER BY` inside an aggregate are newer.
///
/// JSON values lose their JSON subtype when they leave a subquery, a CTE
/// column, or a `CASE` or `coalesce`, and would then embed as strings. So a
/// JSON function's result goes straight into `json_object`, `json_set` or
/// `json_group_array`, and only a value that is always JSON text and crosses
/// such a boundary is wrapped in `json()`. A path that may hold a string or
/// a number is never wrapped: `json()` rejects bare text.
extension OpenCodeProbe {
    /// Slimmed rows larger than this arrive without their data.
    static let rowDataLimit = 1_048_576
    /// Tool output on ordinary reads, in characters.
    static let toolOutputLimit = 16_384
    /// Inbox items, and the characters of each item's text.
    static let inboxItemLimit = 16
    static let inboxTextLimit = 16_384
    /// Open rows a poll reads again by `seq`.
    static let openRowLimit = 64

    static func statements(_ query: OpenCodeQuery) -> [String] {
        let session = "'\(query.session.rawValue)'"
        var statements = [
            versionStatement, tablesStatement, layoutStatement,
            "SELECT 'E ' || coalesce((SELECT seq FROM event_sequence WHERE aggregate_id = \(session)), '')",
            "SELECT 'M' WHERE NOT EXISTS (SELECT 1 FROM session_v2 WHERE id = \(session))",
        ]
        switch query.kind {
        case .tail(let budget):
            statements += [
                sessionStatement(session, changed: "1"),
                newestRows(session, below: nil, budget: budget),
                firstStatement(session, changed: "1"),
                inboxStatement(session, changed: "1"),
            ]
        case .poll(let cursor):
            let changed =
                cursor.eventSeq.map {
                    "(SELECT seq FROM event_sequence WHERE aggregate_id = \(session)) IS NOT \($0)"
                } ?? "1"
            let window = pollWindow(session, cursor: cursor, changed: changed)
            statements += [
                sessionStatement(session, changed: changed),
                """
                \(window)
                SELECT 'R ' || \(rowObject(dataLimit: rowDataLimit))
                  FROM w WHERE acc - len < \(cursor.budget) ORDER BY seq
                """,
                "\(window)\nSELECT 'X' FROM w WHERE acc - len >= \(cursor.budget) LIMIT 1",
                firstStatement(session, changed: changed),
                """
                SELECT 'C ' || (SELECT count(*) FROM session_message WHERE session_id = \(session)
                    AND seq BETWEEN \(cursor.lowSeq) AND \(cursor.highSeq)) WHERE \(changed)
                """,
                inboxStatement(session, changed: changed),
            ]
        case .older(let before, let budget):
            statements += [
                newestRows(session, below: before, budget: budget),
                firstStatement(session, changed: "1"),
            ]
        case .row(let seq, let outputLimit):
            statements.append("""
                WITH r AS (SELECT m.id, m.type, m.seq, m.time_created AS tc, m.time_updated AS tu,
                                  \(finalFlag) AS f, \(slim(outputLimit: max(0, outputLimit))) AS d
                             FROM session_message m WHERE m.session_id = \(session) AND m.seq = \(seq))
                SELECT 'R ' || \(rowObject(dataLimit: nil)) FROM r
                """)
        }
        return statements
    }

    // MARK: Store checks

    static let versionStatement = "SELECT 'V ' || sqlite_version()"

    /// OpenCode 1.x tables, printed only when `session_v2` is absent.
    static let tablesStatement = """
        SELECT 'T ' || m FROM (SELECT group_concat(name, ',') AS m FROM sqlite_master
          WHERE type = 'table' AND name IN ('session', 'message', 'part')
            AND NOT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_v2'))
         WHERE m IS NOT NULL
        """

    /// Every column the queries name, so a changed layout reads as one
    /// problem rather than as the first statement that fails.
    static let layoutStatement = """
        WITH need(t, c) AS (VALUES
          ('session_v2','id'),('session_v2','parent_id'),('session_v2','title'),('session_v2','version'),
          ('session_v2','revert'),('session_v2','time_updated'),
          ('session_message','id'),('session_message','session_id'),('session_message','type'),
          ('session_message','seq'),('session_message','time_created'),('session_message','time_updated'),
          ('session_message','data'),('event_sequence','aggregate_id'),('event_sequence','seq'),
          ('session_inbox','id'),('session_inbox','session_id'),('session_inbox','type'),
          ('session_inbox','payload'),('session_inbox','delivery'),('session_inbox','enqueued_seq'),
          ('session_inbox','time_created'))
        SELECT 'L ' || m FROM (SELECT group_concat(t || '.' || c, ',') AS m FROM need
          WHERE NOT EXISTS (SELECT 1 FROM pragma_table_info(need.t) p WHERE p.name = need.c))
         WHERE m IS NOT NULL
        """

    // MARK: Session, first row and inbox

    /// A staged revert's patches stay in the store: the line carries only
    /// the boundary message, its `seq` and a file count.
    private static func sessionStatement(_ session: String, changed: String) -> String {
        """
        SELECT 'S ' || json_object('k','session','id',id,'parent',parent_id,'title',substr(title,1,512),
          'version',version,
          'revertMessage', json_extract(CASE WHEN json_valid(revert) THEN revert END, '$.messageID'),
          'revertFiles', json_array_length(CASE WHEN json_valid(revert) THEN revert END, '$.files'),
          'revertSeq', (SELECT m.seq FROM session_message m WHERE m.session_id = \(session)
             AND m.id = json_extract(CASE WHEN json_valid(session_v2.revert) THEN session_v2.revert END, '$.messageID')),
          'updated', time_updated)
          FROM session_v2 WHERE id = \(session) AND \(changed)
        """
    }

    private static func firstStatement(_ session: String, changed: String) -> String {
        """
        SELECT 'F ' || coalesce((SELECT min(seq) FROM session_message WHERE session_id = \(session)), '') \
        WHERE \(changed)
        """
    }

    private static func inboxStatement(_ session: String, changed: String) -> String {
        """
        SELECT 'I ' || json_object('k','inbox',
            'items', json(coalesce((SELECT json_group_array(json(item)) FROM (
               SELECT json_object('id',id,'type',type,'delivery',delivery,'seq',enqueued_seq,'tc',time_created,
                 'text', substr(json_extract(CASE WHEN json_valid(payload) THEN payload END,'$.text'),1,\(inboxTextLimit)),
                 'n', length(json_extract(CASE WHEN json_valid(payload) THEN payload END,'$.text')),
                 'files', json(coalesce((SELECT json_group_array(json_extract(f.value,'$.name'))
                            FROM json_each(CASE WHEN json_valid(payload) THEN payload END,'$.files') f
                           WHERE f.type = 'object'), '[]'))) AS item
                 FROM session_inbox WHERE session_id = \(session) ORDER BY enqueued_seq LIMIT \(inboxItemLimit))), '[]')),
            'more', (SELECT max(count(*) - \(inboxItemLimit), 0) FROM session_inbox WHERE session_id = \(session)))
         WHERE \(changed)
        """
    }

    // MARK: Rows

    /// The newest rows within `budget` bytes of slimmed JSON, below `below`
    /// when given, printed oldest first. The newest row always prints. A
    /// prefilter on the stored length bounds how many rows are slimmed.
    private static func newestRows(_ session: String, below: Int64?, budget: Int) -> String {
        let bound = below.map { " AND seq < \($0)" } ?? ""
        return """
            WITH raw AS (SELECT seq, length(data) AS rlen,
                                sum(length(data)) OVER (ORDER BY seq DESC ROWS UNBOUNDED PRECEDING) AS racc
                           FROM session_message WHERE session_id = \(session)\(bound)),
                 r AS (SELECT m.id, m.type, m.seq, m.time_created AS tc, m.time_updated AS tu,
                              \(finalFlag) AS f, \(slim(outputLimit: toolOutputLimit)) AS d
                         FROM session_message m JOIN raw ON raw.seq = m.seq
                        WHERE m.session_id = \(session) AND raw.racc - raw.rlen < 4 * \(budget)),
                 w AS (SELECT *, length(CAST(d AS BLOB)) AS len,
                              sum(length(CAST(d AS BLOB))) OVER (ORDER BY seq DESC ROWS UNBOUNDED PRECEDING) AS acc
                         FROM r)
            SELECT 'R ' || \(rowObject(dataLimit: rowDataLimit))
              FROM w WHERE acc - len < \(budget) ORDER BY seq
            """
    }

    /// The rows a poll reads, oldest first with a running total: newer than
    /// the window, still open, or updated inside it since the last read.
    private static func pollWindow(
        _ session: String, cursor: OpenCodePollCursor, changed: String
    ) -> String {
        let open = cursor.openRows.prefix(openRowLimit).map(String.init).joined(separator: ",")
        return """
            WITH r AS (SELECT m.id, m.type, m.seq, m.time_created AS tc, m.time_updated AS tu,
                              \(finalFlag) AS f, \(slim(outputLimit: toolOutputLimit)) AS d
                         FROM session_message m
                        WHERE m.session_id = \(session) AND \(changed)
                          AND (m.seq > \(cursor.highSeq) OR m.seq IN (\(open.isEmpty ? "NULL" : open))
                               OR (m.seq >= \(cursor.lowSeq) AND m.time_updated >= \(cursor.updatedSince)))),
                 w AS (SELECT *, length(CAST(d AS BLOB)) AS len,
                              sum(length(CAST(d AS BLOB))) OVER (ORDER BY seq ROWS UNBOUNDED PRECEDING) AS acc
                         FROM r)
            """
    }

    /// One `{"k":"row",…}` line from the `w` columns. Over `dataLimit` the
    /// row carries its size as `big` instead of `d`.
    private static func rowObject(dataLimit: Int?) -> String {
        let head = """
            'k','row','id',id,'type',type,'seq',seq,'tc',tc,'tu',tu,\
            'f',json(CASE WHEN f THEN 'true' ELSE 'false' END)
            """
        guard let dataLimit else { return "json_object(\(head),'d',json(d))" }
        return """
            CASE WHEN len <= \(dataLimit) THEN json_object(\(head),'d',json(d))
                   ELSE json_object(\(head),'big',len) END
            """
    }

    /// Whether a row can still change: a step, compaction or shell command
    /// that has not finished.
    private static let finalFlag = """
        CASE WHEN json_valid(m.data) THEN CASE
          WHEN m.type IN ('assistant', 'shell')
            THEN coalesce(json_type(m.data, '$.time.completed'), '') IN ('integer', 'real')
          WHEN m.type = 'compaction' THEN coalesce(json_extract(m.data, '$.status'), '') <> 'running'
          ELSE 1 END ELSE 1 END
        """

    /// The row's data, cut to what Chat shows. A row that is not JSON reads
    /// as `{"k":"invalid"}`.
    private static func slim(outputLimit: Int) -> String {
        """
        CASE WHEN json_valid(m.data) THEN CASE
          WHEN m.type = 'assistant' THEN \(assistant(outputLimit: outputLimit))
          WHEN m.type = 'user' THEN \(user)
          WHEN m.type = 'compaction' THEN json_object('status', json_extract(m.data, '$.status'),
              'reason', json_extract(m.data, '$.reason'),
              'summary', substr(json_extract(m.data, '$.summary'), 1, 65536),
              'time', json_extract(m.data, '$.time'))
          WHEN m.type = 'shell' THEN json_object('command', json_extract(m.data, '$.command'),
              'status', json_extract(m.data, '$.status'), 'exit', json_extract(m.data, '$.exit'),
              'output', substr(json_extract(m.data, '$.output'), 1, \(toolOutputLimit)),
              'n', length(json_extract(m.data, '$.output')), 'time', json_extract(m.data, '$.time'))
          WHEN m.type IN ('synthetic', 'system') THEN json_object(\(note))
          WHEN m.type = 'skill' THEN json_object(\(note),
              'skill', json_extract(m.data, '$.skill'), 'name', json_extract(m.data, '$.name'))
          WHEN m.type IN ('idle', 'agent-switched', 'model-switched', 'location-switched') THEN
            CASE WHEN length(CAST(m.data AS BLOB)) < 4096 THEN m.data
                 ELSE json_object('time', json_extract(m.data, '$.time')) END
          ELSE json_object('time', json_extract(m.data, '$.time')) END
        ELSE json_object('k', 'invalid') END
        """
    }

    /// A step without its provider state or snapshot. Each content item
    /// keeps its index as `_i`.
    private static func assistant(outputLimit: Int) -> String {
        let output = """
            (SELECT group_concat(json_extract(o.value, '$.text'), char(10))
                       FROM json_each(c.value, '$.state.content') o WHERE o.type = 'object')
            """
        return """
            json_set(json_remove(m.data, '$.providerState', '$.snapshot', '$.content'), '$.content',
              json(coalesce((SELECT json_group_array(json(CASE WHEN c.type = 'object' THEN
                  CASE json_extract(c.value, '$.type')
                  WHEN 'text' THEN json_object('_i', c.key, 'type', 'text',
                    'text', substr(json_extract(c.value, '$.text'), 1, 65536),
                    'n', length(json_extract(c.value, '$.text')),
                    'phase', coalesce(json_extract(c.value, '$.state.phase'),
                                      json_extract(c.value, '$.state.openai.phase')))
                  WHEN 'reasoning' THEN json_object('_i', c.key, 'type', 'reasoning',
                    'text', substr(json_extract(c.value, '$.text'), 1, 65536),
                    'n', length(json_extract(c.value, '$.text')),
                    'time', json_extract(c.value, '$.time'))
                  WHEN 'tool' THEN json_object('_i', c.key, 'type', 'tool',
                    'id', json_extract(c.value, '$.id'), 'name', json_extract(c.value, '$.name'),
                    'status', json_extract(c.value, '$.state.status'),
                    'input', json(\(toolInput)),
                    'error', json_extract(c.value, '$.state.error'),
                    'meta', json(\(toolMetadata)),
                    'out', substr(\(output), 1, \(outputLimit)),
                    'outN', length(\(output)),
                    'time', json_extract(c.value, '$.time'))
                  ELSE json_object('_i', c.key, 'type', json_extract(c.value, '$.type')) END
                ELSE json_object('_i', c.key) END))
                FROM json_each(m.data, '$.content') c), '[]')))
            """
    }

    /// An input of 8 KiB or less whole; a larger one keeps the fields a row
    /// names; a text input as a string.
    private static let toolInput = """
        CASE json_type(c.value, '$.state.input')
          WHEN 'object' THEN
            CASE WHEN length(CAST(json_extract(c.value, '$.state.input') AS BLOB)) <= 8192
              THEN json_extract(c.value, '$.state.input')
              ELSE json_object('filePath', json_extract(c.value, '$.state.input.filePath'),
                'path', json_extract(c.value, '$.state.input.path'),
                'command', substr(json_extract(c.value, '$.state.input.command'), 1, 2048),
                'pattern', json_extract(c.value, '$.state.input.pattern'),
                'description', json_extract(c.value, '$.state.input.description'),
                'url', json_extract(c.value, '$.state.input.url'),
                'query', json_extract(c.value, '$.state.input.query'),
                'agent', json_extract(c.value, '$.state.input.agent'),
                'prompt', substr(json_extract(c.value, '$.state.input.prompt'), 1, 2048),
                'questions', json_extract(c.value, '$.state.input.questions')) END
          WHEN 'text' THEN json_quote(substr(json_extract(c.value, '$.state.input'), 1, 2048))
          END
        """

    /// Tool metadata without diagnostics, previews, full output or file
    /// contents; diffs and each file's patch cut at 64 Ki characters.
    private static let toolMetadata = """
        CASE WHEN json_type(c.value, '$.state.metadata') = 'object' THEN json_replace(
          json_remove(json_extract(c.value, '$.state.metadata'), '$.diagnostics', '$.preview',
            '$.output', '$.loaded', '$.filediff.before', '$.filediff.after'),
          '$.diff', substr(json_extract(c.value, '$.state.metadata.diff'), 1, 65536),
          '$.files', json(coalesce((SELECT json_group_array(json_object(
              'file', coalesce(json_extract(f.value, '$.file'), json_extract(f.value, '$.relativePath'),
                               json_extract(f.value, '$.filePath')),
              'status', coalesce(json_extract(f.value, '$.status'), json_extract(f.value, '$.type')),
              'additions', json_extract(f.value, '$.additions'),
              'deletions', json_extract(f.value, '$.deletions'),
              'patch', substr(coalesce(json_extract(f.value, '$.patch'), json_extract(f.value, '$.diff')),
                              1, 65536)))
            FROM json_each(c.value, '$.state.metadata.files') f WHERE f.type = 'object'), '[]'))) END
        """

    private static let user = """
        json_object('text', substr(json_extract(m.data, '$.text'), 1, 262144),
          'n', length(json_extract(m.data, '$.text')),
          'files', json(coalesce((SELECT json_group_array(json_object('name', json_extract(f.value, '$.name'),
                'mime', json_extract(f.value, '$.mime'), 'mention', json_extract(f.value, '$.mention')))
              FROM json_each(m.data, '$.files') f WHERE f.type = 'object'), '[]')),
          'agents', json_extract(m.data, '$.agents'),
          'time', json_extract(m.data, '$.time'))
        """

    /// The `json_object` arguments shared by synthetic, system and skill rows.
    private static let note = """
        'text', substr(json_extract(m.data, '$.text'), 1, 16384),
              'n', length(json_extract(m.data, '$.text')),
              'description', json_extract(m.data, '$.description'),
              'metadata', json(CASE WHEN json_type(m.data, '$.metadata') = 'object' THEN json_object(
                'source', json_extract(m.data, '$.metadata.source'),
                'childID', json_extract(m.data, '$.metadata.childID'),
                'state', json_extract(m.data, '$.metadata.state'),
                'exit', json_extract(m.data, '$.metadata.exit'),
                'notice', json_extract(m.data, '$.metadata.notice'),
                'jobID', json_extract(m.data, '$.metadata.jobID'),
                'shellID', json_extract(m.data, '$.metadata.shellID'),
                'truncated', json_extract(m.data, '$.metadata.truncated')) END),
              'time', json_extract(m.data, '$.time')
        """
}
