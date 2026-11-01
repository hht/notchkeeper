/// 回答：内置插件的 id。外部插件的 id 是 `plugins/<id>/` 的目录名，不能用这些（设置里的开关、顺序按 id 存，重名就串了）
public enum PluginID {
    public static let exitGuard = "guard"
    public static let claudeCode = "claude"
    public static let builtIn: Set<String> = [exitGuard, claudeCode]
    /// 自带的终端插件：算外部插件（走收件箱），但 `plugins/terminal/` 归 App，每次启动整个换成新版，不能装别的插件进去
    public static let terminal = "terminal"
}
