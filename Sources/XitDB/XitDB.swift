/// The name of this module.
///
/// The library has no database code yet. This internal constant gives the
/// gate something to build, and its test shows that the test target reaches
/// internal declarations in both debug and release builds. It goes away when
/// the first real code lands.
let moduleName = "XitDB"
