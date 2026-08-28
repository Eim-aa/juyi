# 原生翻译 Domain 4A：默认关闭的开发切片

状态：**仅供开发验证，未接入用户功能，普通 Debug 与所有 Release 均不包含实现。**

三个 Swift 源文件整体位于唯一的 `#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN` 编译条件内。只有开发者显式构建 Debug 并同时注入该条件时，纯 domain 才会进入产物；默认 xcconfig、legacy 构建脚本、App 启动流程、菜单和运行时设置都没有入口或开关。即使向 Release 单独注入自定义条件，因缺少 `DEBUG`，实现仍会被编译器完全移除。

当前 Python 后端和 Hammerspoon 仍是唯一生产翻译链。4A 不读取真实选区，不监听 Option，不显示浮窗，不访问 localhost，不建立网络请求，也不调用 Apple Translation、Keychain、文件系统或系统剪贴板。它只提供可由命令行测试驱动的纯 Swift 迁移基座：

- `NativeTranslationDomain.swift`：固定 en→zh 的输入策略、闭合的 Apple/火山引擎、Apple 准备状态、火山隐私许可路由、互斥 typed outcome、generation 失效控制与可注入 fake executor。
- `VolcV4RequestBuilder.swift`：以注入的绝对时间、凭据与文本生成确定性的火山 V4 签名数据；不读系统时钟、不发送请求。正文 JSON 与现有 Python `json.dumps(ensure_ascii=False)` 字节一致，并把同一份 `Data` 用于 payload hash。
- `VolcTranslationResponseParser.swift`：只解析测试传入的 HTTP status 和 `Data`。它将状态码与白名单 API code 映射为稳定错误，不把上游 code、message、body、原文或失败译文保留在公开 outcome 中。

## 安全与行为边界

Domain 只有 `.apple` 与 `.volc` 两个可请求引擎；unknown、missing、旧 `argos` 字符串不属于其 API，旧值迁移留在未来单独的 legacy boundary。请求的引擎和成功引擎必须相同，Apple 与火山之间都没有自动切换。Apple 只有 `.installed` 可进入 fake effect；`.supportedNeedsPreparation`、`.unsupported` 和 `.temporarilyUnavailable` 均直接产生无正文的 typed failure。临时不可用状态供另一个独立编译门内的 Apple Translation 开发适配器在无法按时确认系统状态时 fail closed。

火山正文执行必须同时满足：用户已明确同意云端、删除标记已被确认不存在、当前凭据状态为 active、active fingerprint 与已验证 fingerprint 完全一致。任一条件缺失都会在读取凭据快照和执行 fake effect 之前失败；pending 凭据永远不会进入正文请求。4A 不实现任何正文/译文缓存，相同输入连续请求会执行两次。

输入顺序固定为：nil 映射空字符串；CRLF 与 CR 归一化为 LF；按 Unicode scalar 的 `isWhitespace` 去掉外围空白；截取前 5000 个 Unicode scalar；再按冻结的 CJK 范围与 `> 0.5` 比例拒绝明显非英文；最后 alphabetic scalar 少于 2 个时返回 `.skipped(.tooShort)`。内部内容不做 NFC/NFKC，失败与 skipped 都不携带原文或译文。

每个请求取得新 generation。新请求、暂停、停止、辅助功能撤权、引擎/凭据/删除状态/owner 变化都会推进 generation、取消任务并释放暂存输入；effect 返回后和 publish 前再次核对 generation，旧成功、旧失败和旧取消均不能发布。当前 generation 的 executor cancellation 只产生 `.cancelled`，不是用户错误。

## 确定性签名与解析验证

V4 profile 固定为 `POST /`、`translate.volcengineapi.com`、`cn-north-1`、`translate`，query 为 `Action=TranslateText&Version=2020-06-01`。query 编码使用 RFC 3986 unreserved 集合、UTF-8 percent encoding、大写十六进制并按编码后的 key/value 排序；空格不是 `+`。时间格式器显式使用 `en_US_POSIX`、Gregorian 与 GMT，且时间必须由调用方注入。

Golden 测试逐字节固定 Python body、payload SHA-256、canonical request hash、四级 raw-data HMAC 和 Authorization；还覆盖空 source omission、Unicode、引号、反斜杠、控制字符、slash、U+2028/U+2029、非 BMP、UTC 年界及 header injection。凭据、请求、输入、成功和 effect result 的文字描述均为安全摘要，不回显正文或密钥。

签名输入另有一层 App hardening，不尝试猜测或修复异常凭据：AK 与 SK 均以 UTF-8 bytes 计为 1...256。AK 只接受 ASCII 字母、数字、`-._`；SK 只接受 ASCII graphic `0x21...0x7E`，因此 C0 控制字符、CR/LF、NUL、DEL、空格、非 ASCII 与超长值全部 fail closed。固定 en→zh domain 之外，builder 的非空语言标识最多 32 bytes，只接受 ASCII 字母、数字与 `-`；source 的空字符串仍按既有 Python profile 合法省略。这些约束是句译本地安全边界，不是对火山所有可能凭据格式的普遍声明。

响应 parser 仅接受 2xx 且 `TranslationList[0].Translation` 为非空 String 的成功数据。401/403、408/504、429、5xx 与其他非 2xx 分别映射稳定 typed failure；2xx 的 `ResponseMetadata.Error` 只按显式 code 白名单分类，未知 code 统一为服务错误。畸形、空值、错误类型与超大 payload 均 fail closed。

4A 对非 2xx 的精度有一个刻意保守的边界：parser 只依据 status，不解析失败 body。若火山未来用 HTTP 400 搭配 body code 表示更细的凭据或限流原因，4A 会统一返回 `.volcHTTP`。这避免把失败 body/code/message 带入 domain，也意味着错误提示暂时可能较粗；4C 连接真实 transport 前须用脱敏官方响应 fixture 验证实际状态码，再以显式白名单单独评审是否扩充分类。

CI 同时验证默认 Debug、显式 domain Debug、默认 Release、注入 domain flag 的 Release，并扫描真实 Mach-O：只有显式 domain Debug 可以包含 build sentinel、签名 builder 与火山 host。纯 Swift 可执行测试不使用 TCC、网络或 GUI；Xcode 与 legacy source list 都包含这三个文件，但默认构建条件不启用其内容。

后续网络 transport、live Apple Translation、Keychain/删除标记读取、真实选区、domain→浮窗连接以及原生/Hammerspoon owner lease 均不属于 4A，在相应阶段完成独立安全与真机验收前不得启用。
