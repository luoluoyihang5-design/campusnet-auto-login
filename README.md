# 校园网自动登录

Windows 登录后，自动检测校园网的网页认证并完成登录。适用于当前使用「校园宽带」认证页的校园网环境。

## 动态 IP 适配

- **每次读取当前 IPv4。** 脚本根据校园网默认网关识别网卡，取本次分配的 IPv4，并让联网探测从这个地址发出。电脑换了 IP 后可以直接使用，无需重新配置。
- **核对认证跳转。** 从本次探测的重定向取得登录入口，只接受预设认证地址，并要求跳转里的 `userip` 与网卡当前地址一致。遇到不认识的跳转或接口不明确时，跳过登录。
- **先判断是否已经在线。** 在线时直接结束。提交表单后，用同一个源 IP 再次探测，确认恢复联网。

脚本负责连上校园网之后的网页认证。请先在 Windows 里连接校园网 Wi-Fi 或有线网络。其他学校的网关和认证页可能不同，需要适配后再使用。

## 环境和安装

需要 Windows、PowerShell 7、Microsoft Edge，以及 Windows 自带的 curl 和 Windows Script Host（JScript）。在校园网覆盖范围内，从仓库目录用 PowerShell 7 执行：

```powershell
.\CampusNet-AutoLogin.ps1 -Setup
```

按提示输入校园网账号和密码。脚本将凭据保存到当前 Windows 用户的本机目录，Windows 会为密码加密。安装会注册计划任务，在当前用户登录 Windows 时后台启动。已有的旧探测任务 `CampusNet-Probe` 会被停用。

```powershell
# 检查网络、任务与最近一次运行状态
.\CampusNet-AutoLogin.ps1 -Check

# 已安装且处于待认证状态时，手动触发
Start-ScheduledTask -TaskName CampusNet-AutoLogin
```

如果已经安装，从 GitHub 下载最新版脚本（或在本地仓库执行 `git pull --ff-only`）后，用 PowerShell 7 运行：

```powershell
.\CampusNet-AutoLogin.ps1 -Update
```

更新会自检后台启动器，并保留已配置的凭据。更新 Git 仓库后，仍需执行上面的命令，已安装的开机任务才会使用新版。

自动登录需要已解锁的交互式桌面。脚本用 Edge 填写学校的认证页，确认联网后会尝试关闭当前 Windows 会话里的所有 Edge 窗口。已有认证窗口可复用。认证失败时会提示原因，并尝试关闭本次任务新开的认证窗口。手动测试前请先保存浏览器里的工作。认证入口使用 HTTP，本机凭据的加密存储与网络传输加密是两回事。

## 排查与停用

- `campus_interface_unavailable`：检查是否连上校园网，且只有一个匹配的 IPv4 地址。
- `already_online`：探测成功，无需登录。
- `login_verified`：提交后已重新探测并确认联网。
- `portal_rejected`：认证页返回登录失败。
- `portal_form_unavailable`：等待超时，未找到认证表单。
- `submitted_unverified`：表单已提交，尚未确认联网。可在 Edge 手动检查认证页。
- `portal_returned_after_close`：关闭 Edge 后再次出现认证跳转。

暂时停用时，执行 `Disable-ScheduledTask -TaskName CampusNet-AutoLogin`。本机脚本、凭据和最近运行结果位于 `%LOCALAPPDATA%\CampusNet-AutoLogin`。分享排查信息前，请去掉日志里的本机 IP 等信息。
