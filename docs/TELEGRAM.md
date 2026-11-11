# Telegram 机器人

仓库内置一个 Telegram 机器人，全部跑在 GitHub Actions 上，不需要服务器。没配置的部分自动跳过。

| 功能 | 文件 | 开关 |
| --- | --- | --- |
| 发版通知：推送到群并置顶（取消上一版的置顶） | [ci.yml](../.github/workflows/ci.yml) 发布 job 最后一步、[telegram-notify.yml](../.github/workflows/telegram-notify.yml) | `TELEGRAM_CHAT_ID` |
| 新 issue、issue 新回复推送到群 | [telegram-notify.yml](../.github/workflows/telegram-notify.yml) | `TELEGRAM_CHAT_ID` |
| 命令：`/releases`、`/release <tag>`、`/issues`、`/issue <编号>`、`/help` | [telegram-bot.yml](../.github/workflows/telegram-bot.yml) | `TELEGRAM_BOT_ENABLED` |
| 入群验证：申请入群的人要先答对一道加法题 | 同上 | `TELEGRAM_BOT_ENABLED` + 群设置 |

脚本在 [.github/scripts/](../.github/scripts/)：`tg-notify.mjs` 负责推送，`telegram-bot.mjs` 负责命令和入群验证。

## 配置

1. 找 [@BotFather](https://t.me/BotFather) 新建一个机器人，记下 token。
   **不要和别的仓库共用同一个机器人**：命令机器人靠 `getUpdates` 轮询，两个仓库都轮询同一个机器人，会互相把对方的消息确认掉。
2. 把机器人拉进交流群，设为管理员，打开「置顶消息」和「邀请用户」权限（前者用于置顶发版消息，后者用于入群验证）。
3. 取群的 chat id：在群里随便发条消息，浏览器打开 `https://api.telegram.org/bot<token>/getUpdates`，找 `result[].message.chat.id`（群一般是 `-100` 开头的负数）。
   拿到之后再启用命令机器人，否则这条消息会被它先确认掉。
4. 仓库 **Settings → Secrets and variables → Actions**：
   - **Secrets** → `TELEGRAM_BOT_TOKEN` = 第 1 步的 token
   - **Variables** → `TELEGRAM_CHAT_ID` = 第 3 步的 chat id
   - **Variables** → `TELEGRAM_BOT_ENABLED` = `true`（要命令机器人和入群验证才设）
5. 测试：Actions → telegram-notify → **Run workflow**，会把最新 release 发到群里并置顶；Actions → telegram-bot → **Run workflow** 立即处理一次命令。

## 发版通知

推 `v*` 标签后，`ci.yml` 的发布 job 建好 release，最后一步把它发到群里。
用 `GITHUB_TOKEN` 发出的 release 不会触发其他工作流的 `release` 事件，所以通知不能只放在 `telegram-notify.yml` 里；`telegram-notify.yml` 的 `release` 事件只在网页上手动发版时起作用。

推送的是发布那一刻的 release 正文，去掉每版都一样的「## 安装」一节，末尾附升级方法。
之后再改 release 正文不会重发；想重发就手动 Run 一次 telegram-notify（发的是最新 release，会重新置顶）。

## 命令机器人和入群验证

每 5 分钟（cron 最小间隔）用 `getUpdates` 拉一次消息，处理完用 `offset` 向 Telegram 确认，状态由 Telegram 保存，不需要存储。

- 命令不是实时的：cron 最小 5 分钟，GitHub 还常再晚 10～15 分钟。
- 仓库 60 天没有提交，GitHub 会暂停定时任务，去 Actions 页重新启用即可。

入群验证还需要把群设为「新成员需管理员批准」（群设置 → 邀请链接 → Request Admin Approval）。申请的人在被批准前看不到群、发不了消息，机器人私聊发一道选择题，答对放行，连错 3 次拒绝。

Telegram 只允许机器人在入群申请后 5 分钟内私聊申请人，而轮询常常晚于 5 分钟，所以验证题大多发不出去。
这时申请人仍在待批准状态，不会被自动拒绝，需要管理员在 Telegram 里手动批准。
要让验证题稳定送达，得让机器人近实时收到消息：改成 webhook（Cloudflare Workers 等），或者在自己的机器上常驻跑长轮询，`telegram-bot.mjs` 里的逻辑可以直接复用。
