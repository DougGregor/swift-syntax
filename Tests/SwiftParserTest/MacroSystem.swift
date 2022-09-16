@_spi(RawSyntax) import SwiftSyntax
@_spi(RawSyntax) import SwiftParser
import XCTest
import Foundation

// MARK: Macro system definition and application.
protocol Macro {
  func expandExpression(node: MacroExpansionExprSyntax) -> ExprSyntax
}

class MacroApplication : SyntaxRewriter {
  var macroSystem: MacroSystem

  init(macroSystem: MacroSystem) {
    self.macroSystem = macroSystem
  }

  override func visit(_ node: MacroExpansionExprSyntax) -> ExprSyntax {
    let name = node.macro.text
    guard let macro = macroSystem.macros[name] else {
      return ExprSyntax(node)
    }

    return macro.expandExpression(node: node)
  }
}

struct MacroSystem {
  var macros: [String : Macro] = [:]

  func applyMacros(_ node: SourceFileSyntax) -> Syntax {
    return Syntax(MacroApplication(macroSystem: self).visit(node))
  }
}

// MARK: Macros in the macro system
struct EmbedMacro: Macro {
  func expandExpression(node: MacroExpansionExprSyntax) -> ExprSyntax {
    guard let firstArg = node.argumentList.first,
          let stringLiteral = firstArg.expression.as(
            StringLiteralExprSyntax.self),
          stringLiteral.segments.count == 1,
          let filenameSegment = stringLiteral.segments.first else {
      // FIXME: Emit an error.
      return ExprSyntax(node)
    }

    let filename = filenameSegment.description
    let url = URL(fileURLWithPath: filename)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      // FIXME: Emit an error
      return ExprSyntax(node)
    }

    var elements: [ArrayElementSyntax] = []
    let trailingComma = TokenSyntax(.comma, presence: .present)
    for (i, byte) in data.enumerated() {
      elements.append(
        ArrayElementSyntax(
          expression: ExprSyntax(
            IntegerLiteralExprSyntax(
              digits: TokenSyntax(
                .integerLiteral("\(byte)"), presence: .present
              )
            )
          ),
          trailingComma: i < data.count - 1 ? trailingComma : nil)
        )
    }

    return ExprSyntax(
      ArrayExprSyntax(
        leftSquare: TokenSyntax(.leftSquareBracket, presence: .present),
        elements: ArrayElementListSyntax(elements),
        rightSquare: TokenSyntax(.rightSquareBracket, presence: .present)
      )
    )
  }
}

extension String {
  fileprivate var isRelationalOperator: Bool {
    switch self {
    case "==", "!=", "<", ">", "<=", ">=":
      return true

    default:
      return false
    }
  }
}

struct AssertMacro: Macro {
  func expandExpression(node: MacroExpansionExprSyntax) -> ExprSyntax {
    guard node.argumentList.count == 1, node.trailingClosure == nil,
      let firstArg = node.argumentList.first,
          firstArg.label == nil else {
      // FIXME: Emit an error.
      return ExprSyntax(node)
    }

    let arg = firstArg.expression

    // Check for a sequence with a relational operator in it.
    // FIXME: If we did this after operator precedence parsing, it would just
    // be an infix binary expression we'd be looking at.
    if let sequenceExpr = arg.as(SequenceExprSyntax.self),
       sequenceExpr.elements.count == 3,
       let operatorExpr = sequenceExpr.elements.dropFirst().first,
       let operatorSyntax = operatorExpr.as(BinaryOperatorExprSyntax.self),
       operatorSyntax.operatorToken.text.isRelationalOperator,
       let lhs = sequenceExpr.elements.first,
       let rhs = sequenceExpr.elements.dropFirst(2).first {
      
      let syntax: ExprSyntax =
        """
        {
          let __a = \(lhs.withoutTrailingTrivia())
          let __b = \(rhs.withoutTrailingTrivia())
          if !(__a \(operatorSyntax) __b) {
            fatalError("Assertion '\(lhs.description) \(operatorSyntax) \(rhs.description)' failed with values \\(__a), \\(__b)")
          }
        }()
        """

      return syntax
    }

    return ExprSyntax(node)
  }
}

final class MacroSystemTests: XCTestCase {
  func testEmbedMacroExpansion() {
    let sf: SourceFileSyntax =
      """
      let data = #embed("\(#filePath)")
      """

    var macroSystem = MacroSystem()
    macroSystem.macros["embed"] = EmbedMacro()

    let transformedSF = macroSystem.applyMacros(sf)

    let expectedText = "testEmbedMacroExpansion".utf8.map {
      "\($0)"
    }.joined(separator: ",")
    XCTAssertTrue(transformedSF.description.contains(expectedText))
  }

  func testAssertMacroExpansion() {
    let sf: SourceFileSyntax =
      """
      #myassert((x * 12) == (y + 4))
      """
    var macroSystem = MacroSystem()
    macroSystem.macros["myassert"] = AssertMacro()

    let transformedSF = macroSystem.applyMacros(sf)
    print(transformedSF.description)
    print(transformedSF.recursiveDescription)
    AssertStringsEqualWithDiff(
      transformedSF.description,
      """
      {
        let __a = (x * 12)
        let __b = (y + 4)
        if !(__a ==  __b) {
          fatalError("Assertion '(x * 12)  ==  (y + 4)' failed with values \\(__a), \\(__b)")
        }
      }()
      """
    )
  }
}
