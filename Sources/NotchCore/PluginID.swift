/// 回答：内置插件的 id。外部插件的 id 是 `plugins/<id>/` 的目录名，不能用这些（设置里的开关、顺序按 id 存，重名就串了）
public enum PluginID {
    public static let exitGuard = "guard"
    public static let claudeCode = "claude"
    public static let builtIn: Set<String> = [exitGuard, claudeCode]
}
