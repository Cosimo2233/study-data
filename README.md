# 学习资料整理

整理课程课件、学习笔记、习题和课程作业，资料按课程打包为 ZIP 文件。

## 主要内容

- 数学：高数课件、高等数学笔记、线代、复变函数与积分变换。
- 电子与电路：电路、数电、模电、电子科技制作。
- 其他课程：大物下、测控导论等。

## 下载与使用

按需下载对应的 ZIP 文件，解压后查看。

`电路.zip` 使用 Git LFS 存储，在 GitHub 文件页面下载原始文件即可。通过 Git 克隆时，需先安装 Git LFS：

```bash
git lfs install
git clone https://github.com/Cosimo2233/study-data.git
```

资料仅供个人学习参考，版权归原作者或出版方所有。

## 更新并上传

修改科目文件夹中的资料后，双击根目录的 `Upload-Study.cmd`。脚本会重新打包有变化的文件夹，自动提交并推送 ZIP 到 GitHub，完成后退出，不在后台运行。

- 新增、修改、删除的文件都会反映到对应压缩包；本地源文件保留。
- 沿用 `.gitignore`：“26电赛E题”和指定的个人 ZIP 不会上传。
- 根目录的《电路》PDF 会更新到现有 `电路.zip`，保留包内其他资料。
- 超过 100 MiB 的 ZIP 自动使用 Git LFS；需已安装 Git、Git LFS 并登录 GitHub。
- 网络失败后可再次运行，脚本会重试推送；若已有手动暂存的改动，会先停止，避免混入提交。

也可在 PowerShell 中运行：`powershell -NoProfile -ExecutionPolicy Bypass -File .\Upload-Study.ps1`。
