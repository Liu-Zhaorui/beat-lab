# 🎵 BEAT LAB

**BEAT LAB** 是一款面向钢琴调律师与音乐爱好者的实时拍频可视化工具，集成音叉生成器，兼具分析与调音两大核心功能。

---

## ✨ 功能特性

- **实时拍频可视化**：通过麦克风捕获音频，实时检测两音之间的拍频（beat frequency），以动态波形呈现。
- **音程分析**：FFT 频谱分析 + 抛物线插值，自动识别音程、谐波对，以及锁定最强音程。
- **音叉发生器**：内置正弦波音叉，支持通过滚轮精确调节频率（Hz），提供纯净参考音。
- **节拍深度可视化**：显示拍频包络强度、拍频置信度、活跃音调数等多维指标。
- **流畅动画 UI**：基于 Flutter Material 3，配色现代，体验流畅。

---

## 📸 截图

> *(可在 releases 文件夹中下载安装包体验)*

---

## 🚀 安装体验

### Android 直接安装
从本仓库 [`releases/`](releases/) 文件夹下载 `app-release.apk`，在安卓设备上允许"未知来源"后直接安装。

### 从源码运行

**环境要求：**
- Flutter SDK `^3.11.5` 及以上
- Dart `^3.0`
- Android Studio / VS Code

**步骤：**
```bash
# 1. 克隆仓库
git clone https://github.com/<your-username>/beat-lab.git
cd beat-lab

# 2. 获取依赖
flutter pub get

# 3. 连接设备或启动模拟器后运行
flutter run

# 4. 构建 Release APK（可选）
flutter build apk --release
```

---

## 📦 依赖说明

| 包名 | 用途 |
|---|---|
| `record` ^6.1.1 | 麦克风 PCM 音频流捕获 |
| `sound_generator` ^0.0.14 | 正弦波音叉发生器 |
| `flutter / cupertino_icons` | UI 框架与图标 |

---

## 🛠️ 技术原理

1. **实时 PCM 采集**：通过 `record` 包以 44100 Hz 采样率持续读取麦克风数据。
2. **FFT 频谱分析**：对 PCM 帧执行快速傅里叶变换，抛物线插值提升频率精度。
3. **谐波感知音程检测**：在检测到的频率中匹配谐波对，计算拍频（|f1 - f2|）。
4. **包络提取**：对信号幅度做平滑处理，输出拍深度（beat depth）用于可视化强度。
5. **音叉发生器**：使用 `sound_generator` 生成纯正弦波，频率由用户通过 iOS 风格滚轮调节。

---

## 👤 作者

**Liu Zhaorui（刘兆蕤）**  
本项目为个人学习与实践项目，欢迎 Issue 与 PR。

---

## 📄 License

MIT License

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
