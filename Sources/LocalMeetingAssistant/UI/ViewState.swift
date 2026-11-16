import SwiftUI

/// В SDK macOS 27 атрибут `@State` реализован макросом, плагин которого поставляется только с Xcode.
/// Псевдоним ссылается напрямую на тип-обёртку, поэтому проект собирается одними Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
