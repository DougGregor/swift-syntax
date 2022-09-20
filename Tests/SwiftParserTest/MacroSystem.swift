@_spi(RawSyntax) import SwiftSyntax
import SwiftOperators
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
    let foldedSF = OperatorTable.standardOperators.foldAll(node) { error in }
      .as(SourceFileSyntax.self)!
    return Syntax(MacroApplication(macroSystem: self).visit(foldedSF))
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

    // Check for an infix operator expression with a relational operator.
    if let infixOperatorExpr = arg.as(InfixOperatorExprSyntax.self),
       let operatorSyntax =
         infixOperatorExpr.operatorOperand.as(BinaryOperatorExprSyntax.self),
       operatorSyntax.operatorToken.text.isRelationalOperator {

      let lhs = infixOperatorExpr.leftOperand
      let rhs = infixOperatorExpr.rightOperand
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

fileprivate extension CodeBlockItemSyntax {
  init<Node: SyntaxProtocol>(_ node: Node) {
    self.init(item: Syntax(node), semicolon: nil, errorTokens: nil)
  }
}

struct ResultBuilderRewriter {
  let resultBuilderType: ExprSyntax
  var counter: Int = 0

  mutating func rewrite(_ closure: ClosureExprSyntax) -> ClosureExprSyntax {
    let newStatements = rewrite(closure.statements) { [resultBuilderType] result in
      let returnStmt: StmtSyntax =
        """
        \nreturn \(resultBuilderType).buildFinalResult(\(result))
        """
      return CodeBlockItemSyntax(returnStmt)
    }.0

    return closure.withStatements(newStatements)
  }

  /// Declare a fresh local variable with the given initializer (if any).
  private mutating func declareFreshLocal(
    _ initializer: ExprSyntax?,
    wrapInitializer: ((ExprSyntax) -> ExprSyntax)? = nil
  ) -> (DeclSyntax, ExprSyntax) {
    let localName: ExprSyntax = "_value\(counter)"
    counter += 1

    guard let initializer = initializer else {
      return ("let \(localName)", localName)
    }

    let leadingTrivia = initializer.leadingTrivia?.description ?? ""
    let bareInitializer = initializer.withoutLeadingTrivia()
    let finalInitializer = wrapInitializer?(bareInitializer) ?? bareInitializer
    return ("\(leadingTrivia)let \(localName) = \(finalInitializer)", localName)
  }

  private mutating func rewrite(
    _ item: CodeBlockItemSyntax
  ) -> (CodeBlockItemSyntax, ExprSyntax?) {
    // Expressions get captured into values.
    if let expr = item.item.as(ExprSyntax.self) {
      let (decl, local) = declareFreshLocal(expr) { [resultBuilderType] initializer in
        "\(resultBuilderType).buildExpression(\(initializer))"
      }
      return (CodeBlockItemSyntax(decl), local)
    }

    // Ignore anything we don't recognize.
    return (item, nil)
  }

  private mutating func rewrite(
    _ codeBlock: CodeBlockItemListSyntax,
    withFinalResult resultBody: (ExprSyntax) -> CodeBlockItemSyntax?
  ) -> (CodeBlockItemListSyntax, ExprSyntax) {
    // Transform each of the items.
    var resultValues: [ExprSyntax] = []
    var newItems: [CodeBlockItemSyntax] = []
    for item in codeBlock {
      let (newItem, newItemName) = rewrite(item)
      newItems.append(newItem)

      if let newItemName = newItemName {
        resultValues.append(newItemName)
      }
    }

    let flatResultArguments = resultValues.map {
      $0.description
    }.joined(separator: ", ")
    let (blockResultDecl, blockResultName) = declareFreshLocal(
      """
      \n\(resultBuilderType).buildBlock(\(flatResultArguments))
      """
    )
    newItems.append(CodeBlockItemSyntax(blockResultDecl))

    if let finalCodeItem = resultBody(blockResultName) {
      newItems.append(finalCodeItem)
    }

    return (CodeBlockItemListSyntax(newItems), blockResultName)
  }
}

struct ResultBuilderMacro: Macro {
  func expandExpression(node: MacroExpansionExprSyntax) -> ExprSyntax {
    guard node.argumentList.count == 1,
          let resultBuilderArg = node.argumentList.first,
          resultBuilderArg.label == nil,
          let closure = node.trailingClosure else {
      return ExprSyntax(node)
    }

    let resultBuilderType = resultBuilderArg.expression
    var rewriter = ResultBuilderRewriter(resultBuilderType: resultBuilderType)
    return ExprSyntax(rewriter.rewrite(closure))
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

  func testResultBuilderMacroExpansion() {
    let sf: SourceFileSyntax =
      """
      #resultBuilder(ViewBuilder) {
        Image(album.cover)
        Text(song.title)
        Text(song.artist.name)
          .foregroundStyle(.secondary)
      }
      """
    var macroSystem = MacroSystem()
    macroSystem.macros["resultBuilder"] = ResultBuilderMacro()

    let transformedSF = macroSystem.applyMacros(sf)
    print(transformedSF.description)
    print(transformedSF.recursiveDescription)
    AssertStringsEqualWithDiff(
      transformedSF.description,
      """
      {
        let _value0 = ViewBuilder.buildExpression(Image(album.cover))
        let _value1 = ViewBuilder.buildExpression(Text(song.title))
        let _value2 = ViewBuilder.buildExpression(Text(song.artist.name)
          .foregroundStyle(.secondary))
      let _value3 = ViewBuilder.buildBlock(_value0, _value1, _value2)
      return ViewBuilder.buildFinalResult(_value3)
      }
      """
    )
  }
}
