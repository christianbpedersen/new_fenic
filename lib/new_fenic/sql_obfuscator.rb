require "digest/md5"

module NewFenic
  # Normalizes SQL so that statements differing only in literal values group
  # together, and so no customer data leaves the process.
  module SqlObfuscator
    MAX_LENGTH = 2_000
    CACHE_LIMIT = 2_000

    COMMENTS = %r{/\*.*?\*/|--[^\n]*}m
    STRINGS = /'(?:[^']|'')*'|E'(?:[^'\\]|\\.)*'/
    NUMBERS = /(?<![\w$."])-?\b\d+(?:\.\d+)?\b/
    IN_LISTS = /\bIN\s*\(\s*(?:\?|\$\d+)(?:\s*,\s*(?:\?|\$\d+))*\s*\)/i
    VALUES_LISTS = /\bVALUES\s*(\((?:[^()]|\([^()]*\))*\))(?:\s*,\s*\((?:[^()]|\([^()]*\))*\))+/i
    WHITESPACE = /\s+/
    OPERATION = /\A\s*(?:WITH\b.*?\)\s*)?(SELECT|INSERT|UPDATE|DELETE|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|SET|SHOW|CREATE|ALTER|DROP|TRUNCATE|EXPLAIN|LOCK)\b/im
    TABLE_PATTERNS = {
      "SELECT" => /\bFROM\s+"?(?:\w+"?\.)?"?(\w+)"?/i,
      "DELETE" => /\bFROM\s+"?(?:\w+"?\.)?"?(\w+)"?/i,
      "INSERT" => /\bINTO\s+"?(?:\w+"?\.)?"?(\w+)"?/i,
      "UPDATE" => /\bUPDATE\s+"?(?:\w+"?\.)?"?(\w+)"?/i
    }.freeze

    Statement = Struct.new(:sql, :key, :operation, :table)

    @cache = {}
    @mutex = Mutex.new

    module_function

    def call(raw)
      raw = raw.to_s
      cached = @cache[raw]
      return cached if cached

      statement = build(raw)
      @mutex.synchronize do
        @cache.clear if @cache.size >= CACHE_LIMIT
        @cache[raw.frozen? ? raw : raw.dup.freeze] = statement
      end
      statement
    end

    def build(raw)
      sql = raw.gsub(COMMENTS, " ")
      sql = sql.gsub(STRINGS, "?")
      sql = sql.gsub(NUMBERS, "?")
      sql = sql.gsub(IN_LISTS, "IN (...)")
      sql = sql.gsub(VALUES_LISTS) { "VALUES #{Regexp.last_match(1)}, ..." }
      sql = sql.gsub(WHITESPACE, " ").strip
      sql = sql[0, MAX_LENGTH] if sql.length > MAX_LENGTH

      operation = sql[OPERATION, 1]&.upcase || "OTHER"
      table = (pattern = TABLE_PATTERNS[operation]) ? sql[pattern, 1] : nil
      Statement.new(sql.freeze, Digest::MD5.hexdigest(sql), operation, table).freeze
    end
  end
end
