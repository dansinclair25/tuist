extension SynthesizedResourceInterfaceTemplates {
    static let stringsCatalogTemplate = """
    // swiftlint:disable all
    // swift-format-ignore-file
    // swiftformat:disable all
    // Generated using tuist — https://github.com/tuist/tuist

    {% if tables.count > 0 %}
    {% set accessModifier %}{% if param.publicAccess %}public{% else %}internal{% endif %}{% endset %}
    import Foundation

    // swiftlint:disable superfluous_disable_command file_length implicit_return prefer_self_in_static_references

    // MARK: - Strings Catalog

    {% macro parametersBlock types %}
      {%- for type in types -%}
        {%- if type == "String" -%}
        _ p{{forloop.counter}}: Any
        {%- else -%}
        _ p{{forloop.counter}}: {{type}}
        {%- endif -%}
        {{ ", " if not forloop.last }}
      {%- endfor -%}
    {% endmacro %}
    {% macro argumentsBlock types %}
      {%- for type in types -%}
        {%- if type == "String" -%}
        String(describing: p{{forloop.counter}})
        {%- elif type == "UnsafeRawPointer" -%}
        Int(bitPattern: p{{forloop.counter}})
        {%- else -%}
        p{{forloop.counter}}
        {%- endif -%}
        {{ ", " if not forloop.last }}
      {%- endfor -%}
    {% endmacro %}
    {% macro recursiveBlock table item %}
      {% for string in item.strings %}
      {% if not param.noComments %}
      {% for line in string.comment|default:string.translation|split:"\n" %}
      /// {{line}}
      {% endfor %}
      {% endif %}
      {% set translation string.translation|replace:'"','\"'|replace:'    ','\t' %}
      {% if string.types %}
      {{accessModifier}} static func {{string.name|swiftIdentifier:"pretty"|lowerFirstWord|escapeReservedKeywords}}({% call parametersBlock string.types %}) -> String {
        return {{enumName}}.tr("{{table}}", "{{string.key}}", {%+ call argumentsBlock string.types %})
      }
      {% elif param.lookupFunction %}
      {{accessModifier}} static var {{string.name|swiftIdentifier:"pretty"|lowerFirstWord|escapeReservedKeywords}}: String { return {{enumName}}.tr("{{table}}", "{{string.key}}") }
      {% else %}
      {{accessModifier}} static let {{string.name|swiftIdentifier:"pretty"|lowerFirstWord|escapeReservedKeywords}} = {{enumName}}.tr("{{table}}", "{{string.key}}")
      {% endif %}
      {% endfor %}
      {% for child in item.children %}
      {{accessModifier}} enum {{child.name|swiftIdentifier:"pretty"|escapeReservedKeywords}} {
        {% filter indent:2," ",true %}{% call recursiveBlock table child %}{% endfilter %}
      }
      {% endfor %}
    {% endmacro %}
    // swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
    // swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
    {% set enumName %}{{param.enumName}}StringsCatalog{% endset %}
    {{accessModifier}} enum {{enumName}} {
      {% if tables.count > 1 or param.forceFileNameEnum %}
      {% for table in tables %}
      {{accessModifier}} enum {{table.name|swiftIdentifier:"pretty"|escapeReservedKeywords}} {
        {% filter indent:2," ",true %}{% call recursiveBlock table.name table.levels %}{% endfilter %}
      }
      {% endfor %}
      {% else %}
      {% call recursiveBlock tables.first.name tables.first.levels %}
      {% endif %}
    }
    // swiftlint:enable explicit_type_interface function_parameter_count identifier_name line_length
    // swiftlint:enable nesting type_body_length type_name vertical_whitespace_opening_braces

    // MARK: - Implementation Details

    extension {{enumName}} {
      private static func tr(_ table: String, _ key: StaticString, _ args: CVarArg...) -> String {
        return String(
          localized: key,
          defaultValue: defaultValue(key, args),
          table: table,
          bundle: {{param.bundle|default:"BundleToken.bundle"}},
          locale: Locale.current
        )
      }

      private static func defaultValue(_ key: StaticString,
                                        _ args: CVarArg...) -> String.LocalizationValue {
        var stringInterpolation = String.LocalizationValue.StringInterpolation(literalCapacity: 0, interpolationCount: args.count)
        args.forEach { stringInterpolation.appendInterpolation(arg: $0) }
        return .init(stringInterpolation: stringInterpolation)
      }
    }

    private extension String.LocalizationValue.StringInterpolation {
      mutating func appendInterpolation(arg: CVarArg) {
        switch arg {
        case let arg as String: appendInterpolation(arg)
        case let arg as Int: appendInterpolation(arg)
        case let arg as UInt: appendInterpolation(arg)
        case let arg as Double: appendInterpolation(arg)
        case let arg as Float: appendInterpolation(arg)
        default: return
        }
      }
    }
    {% if not param.bundle and not param.lookupFunction %}

    // swiftlint:disable convenience_type
    private final class BundleToken {
      static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: BundleToken.self)
        #endif
      }()
    }
    // swiftlint:enable convenience_type
    {% endif %}
    {% else %}
    // No strings catalog found
    {% endif %}
    // swiftlint:enable all
    
    """
}
