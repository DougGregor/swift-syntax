import SwiftParser
import SwiftSyntax
import XCTest
import _SwiftSyntaxTestSupport

typealias RewrittenSome = (
  ConstrainedSugarTypeSyntax, GenericParameterSyntax,
  SimpleTypeIdentifierSyntax
)

// Rewrite "some" parameters into newly-created generic parameters with names
// T1, T2, ..., TN.
class SomeParameterRewriter: SyntaxRewriter {
  var rewrittenSomeParameters: [RewrittenSome] = []

  override func visit(_ node: ConstrainedSugarTypeSyntax) -> TypeSyntax {
    if node.someOrAnySpecifier.text != "some" {
      return TypeSyntax(node)
    }

    let paramName = "T\(rewrittenSomeParameters.count + 1)"
    let paramNameSyntax = TokenSyntax.identifier(paramName)

    let inheritedType: TypeSyntax?
    let colon: TokenSyntax?
    if node.baseType.description != "Any" {
      colon = .colonToken()
      inheritedType = node.baseType.withLeadingTrivia(.space)
    } else {
      colon = nil
      inheritedType = nil
    }

    let genericParam = GenericParameterSyntax(
      attributes: nil, name: paramNameSyntax, colon: colon,
      inheritedType: inheritedType, trailingComma: nil
    )

    let genericParamRef = SimpleTypeIdentifierSyntax(
      name: .identifier(paramName), genericArgumentClause: nil
    )

    rewrittenSomeParameters.append((node, genericParam, genericParamRef))

    return TypeSyntax(genericParamRef)
  }

  override func visit(_ node: TupleTypeSyntax) -> TypeSyntax {
    let newNode = super.visit(node)

    // If this tuple type is simple parentheses around a replaced "some"
    // parameter, drop the parentheses.
    guard let newTuple = newNode.as(TupleTypeSyntax.self),
          newTuple.elements.count == 1,
          let onlyElement = newTuple.elements.first,
          onlyElement.name == nil,
          onlyElement.ellipsis == nil,
          let onlyIdentifierType =
            onlyElement.type.as(SimpleTypeIdentifierSyntax.self),
          rewrittenSomeParameters.first(
            where: { $0.2.name.text == onlyIdentifierType.name.text }
          ) != nil
    else {
      return newNode
    }

    return TypeSyntax(onlyIdentifierType)
  }
}

class OpaqueParameterToGenericRewriter: SyntaxRewriter {
  /// Replace all of the "some" parameters in the given parameter clause with
  /// freshly-created generic parameters.
  ///
  /// - Returns: nil if there was nothing to rewrite, or a pair of the
  /// rewritten parameters and augmented generic parameter list.
  func replaceSomeParameters(
    in params: ParameterClauseSyntax,
    augmenting genericParams: GenericParameterClauseSyntax?
  ) -> (ParameterClauseSyntax, GenericParameterClauseSyntax)? {
    let rewriter = SomeParameterRewriter()
    let rewrittenParams = rewriter.visit(params.parameterList)

    if rewriter.rewrittenSomeParameters.isEmpty {
      return nil
    }

    var newGenericParams: [GenericParameterSyntax] = []
    if let genericParams = genericParams {
      newGenericParams.append(contentsOf: genericParams.genericParameterList)
    }

    for (_, newGenericParam, _) in rewriter.rewrittenSomeParameters {
      // Add a trailing comma to the prior generic parameter, if there is one.
      if let lastNewGenericParam = newGenericParams.last {
        newGenericParams[newGenericParams.count-1] =
            lastNewGenericParam.withTrailingComma(.commaToken())
        newGenericParams.append(newGenericParam.withLeadingTrivia(.space))
      } else {
        newGenericParams.append(newGenericParam)
      }
    }

    let newGenericParamSyntax = GenericParameterListSyntax(newGenericParams)
    let newGenericParamClause: GenericParameterClauseSyntax
    if let genericParams = genericParams {
      newGenericParamClause = genericParams.withGenericParameterList(
        newGenericParamSyntax
      )
    } else {
      newGenericParamClause = GenericParameterClauseSyntax(
        leftAngleBracket: .leftAngleToken(),
        genericParameterList: newGenericParamSyntax,
        genericWhereClause: nil,
        rightAngleBracket: .rightAngleToken()
      )
    }

    return (
      params.withParameterList(FunctionParameterListSyntax(rewrittenParams)),
      newGenericParamClause
    )
  }

  override func visit(_ funcSyntax: FunctionDeclSyntax) -> DeclSyntax {
    guard let (newInput, newGenericParams) = replaceSomeParameters(
      in: funcSyntax.signature.input,
      augmenting: funcSyntax.genericParameterClause
    ) else {
      return DeclSyntax(funcSyntax)
    }

    return DeclSyntax(
      funcSyntax
        .withSignature(funcSyntax.signature.withInput(newInput))
        .withGenericParameterClause(newGenericParams)
    )
  }
}

final class SomeParameterToGenericTests: XCTestCase {
  func testSomeParameterToGeneric() {
    let source =
      """
      func f(x: some P, y: (some Q & R)?, z: [some Any]) { }
      """

    let parsed = try Parser.parse(source: source)
    let rewritten = OpaqueParameterToGenericRewriter().visit(parsed)

    AssertStringsEqualWithDiff(
      rewritten.description,
      """
      func f<T1: P, T2: Q & R, T3>(x: T1, y: T2?, z: [T3]) { }
      """
    )
  }

  func testSomeParameterToGeneric2() {
    let source =
      """
      func f<T>(x: some P, y: (some Q & R)?, z: [some Any]) { }
      """

    let parsed = try Parser.parse(source: source)
    let rewritten = OpaqueParameterToGenericRewriter().visit(parsed)

    AssertStringsEqualWithDiff(
      rewritten.description,
      """
      func f<T, T1: P, T2: Q & R, T3>(x: T1, y: T2?, z: [T3]) { }
      """
    )
  }
}
