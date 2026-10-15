using System.Text;

namespace RewindTogether.Launcher.Core;

/// <summary>
/// Reader for Valve's text KeyValues format (libraryfolders.vdf, appmanifest_*.acf).
///
/// Values are either strings or nested objects. Keys are case-insensitive, as Steam treats them.
/// Comments (//) and conditional suffixes ([$WIN32]) are skipped. A malformed file throws
/// <see cref="FormatException"/>; callers treat that as "this library could not be read" rather
/// than as a crash.
/// </summary>
public sealed class VdfObject
{
    private readonly List<KeyValuePair<string, object>> _items = new();

    public IReadOnlyList<KeyValuePair<string, object>> Items => _items;

    public void Add(string key, object value) => _items.Add(new(key, value));

    /// <summary>The first string value with this key, or null.</summary>
    public string? GetString(string key)
    {
        foreach (var kv in _items)
            if (string.Equals(kv.Key, key, StringComparison.OrdinalIgnoreCase) && kv.Value is string s)
                return s;
        return null;
    }

    /// <summary>The first object value with this key, or null.</summary>
    public VdfObject? GetObject(string key)
    {
        foreach (var kv in _items)
            if (string.Equals(kv.Key, key, StringComparison.OrdinalIgnoreCase) && kv.Value is VdfObject o)
                return o;
        return null;
    }
}

public static class Vdf
{
    /// <summary>Parses a whole document. The result is the implicit root containing the top-level key(s).</summary>
    public static VdfObject Parse(string text)
    {
        var p = new Parser(text);
        var root = new VdfObject();
        p.ParseBody(root, topLevel: true);
        return root;
    }

    private sealed class Parser
    {
        private readonly string _s;
        private int _i;

        public Parser(string s)
        {
            _s = s;
            if (_s.Length > 0 && _s[0] == '﻿') _i = 1;
        }

        public void ParseBody(VdfObject target, bool topLevel)
        {
            while (true)
            {
                SkipTrivia();
                if (_i >= _s.Length)
                {
                    if (topLevel) return;
                    throw new FormatException("Unexpected end of file: a '{' was never closed.");
                }
                char c = _s[_i];
                if (c == '}')
                {
                    if (topLevel) throw new FormatException($"Unexpected '}}' at offset {_i}.");
                    _i++;
                    return;
                }

                string key = ReadToken() ?? throw new FormatException($"Expected a key at offset {_i}.");
                SkipTrivia();
                SkipConditional();
                SkipTrivia();
                if (_i >= _s.Length) throw new FormatException($"Key \"{key}\" has no value.");

                if (_s[_i] == '{')
                {
                    _i++;
                    var child = new VdfObject();
                    ParseBody(child, topLevel: false);
                    target.Add(key, child);
                }
                else
                {
                    string value = ReadToken() ?? throw new FormatException($"Key \"{key}\" has no value.");
                    target.Add(key, value);
                }
                SkipTrivia();
                SkipConditional();
            }
        }

        private void SkipConditional()
        {
            if (_i < _s.Length && _s[_i] == '[')
            {
                int end = _s.IndexOf(']', _i);
                _i = end < 0 ? _s.Length : end + 1;
            }
        }

        private void SkipTrivia()
        {
            while (_i < _s.Length)
            {
                char c = _s[_i];
                if (char.IsWhiteSpace(c)) { _i++; continue; }
                if (c == '/' && _i + 1 < _s.Length && _s[_i + 1] == '/')
                {
                    while (_i < _s.Length && _s[_i] != '\n') _i++;
                    continue;
                }
                break;
            }
        }

        private string? ReadToken()
        {
            if (_i >= _s.Length) return null;
            if (_s[_i] == '"')
            {
                _i++;
                var sb = new StringBuilder();
                while (_i < _s.Length)
                {
                    char c = _s[_i++];
                    if (c == '"') return sb.ToString();
                    if (c == '\\' && _i < _s.Length)
                    {
                        char n = _s[_i++];
                        sb.Append(n switch { 'n' => '\n', 't' => '\t', 'r' => '\r', '\\' => '\\', '"' => '"', _ => n });
                        continue;
                    }
                    sb.Append(c);
                }
                throw new FormatException("Unterminated quoted string.");
            }

            int start = _i;
            while (_i < _s.Length && !char.IsWhiteSpace(_s[_i]) && _s[_i] is not ('{' or '}' or '"'))
                _i++;
            return _i > start ? _s.Substring(start, _i - start) : null;
        }
    }
}
