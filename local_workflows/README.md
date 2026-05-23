### theos
在 `theos/include/` 已存在的 `YouTubeHeader/PSHeader` 不会被强制重拉，跟 upstream 每次 `rm -rf` 不一致。如果某次构建出现 header API 不匹配，可手动 `rm -rf theos/include/{YouTubeHeader,PSHeader,YTHeaders}` 再跑。

