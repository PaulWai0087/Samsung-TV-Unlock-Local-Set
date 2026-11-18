# 发布维护

普通用户请下载 [GitHub Releases](https://github.com/PaulWai0087/Samsung-TV-Unlock-Local-Set/releases) 中的 Windows x64 ZIP，全部解压后运行 `START.cmd`。

发布工作流只在 `main` 的 `release/request.json` 改动或维护者手动触发时运行。请求文件明确指定版本、完整源码 commit、已成功的 Windows CI run，以及三个资产的预期大小和 SHA256。发布权限限定在该工作流任务；不需要另设个人访问令牌。

## 复现打包

在完整仓库中运行（需要 Git 和 Python 3）：

```bash
python tools/publish_release.py --request release/request.json --output-dir /tmp/local-set-release
```

默认只创建并核对本地文件，不请求 GitHub 写入。输出目录应为空；脚本拒绝覆盖已有资产。打包来源是请求中的固定提交，工作区文件不会混入其中。

在 GitHub Actions 中传入 `--publish` 后，流程还会：

1. 核对指定源码提交的 Windows 自动检查成功，且源码是当前分支历史的一部分。
2. 核对完整文件清单、两份辅助程序清单、版本和 10 页 PDF。
3. 创建草稿 Release 并上传 ZIP、PDF、SHA256SUMS。
4. 下载上传后的全部资产并逐字节核验 SHA256，再正式发布并标记 Latest。
5. 读回 Release 与 tag，核对资产及源码 commit。

如果同名 Release 或 tag 已存在，脚本停止，不覆盖、不移动 tag。上传或核验失败时保留草稿供检查，不会把未经核对的草稿发布；重新运行前需由维护者检查已有状态。

v1.0.2 的资产来自已通过验证的 `101c6cfe2694f6dd669ff71104584051f0373fbe`；发布自动化在此之后加入主分支，因此不在 v1.0.2 工具包中。程序、教程、原有辅助程序与该源码提交完全一致。

GitHub 官方说明：[创建 Release](https://cli.github.com/manual/gh_release_create)、[发布草稿](https://cli.github.com/manual/gh_release_edit)、[工作流令牌与权限](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token)。
