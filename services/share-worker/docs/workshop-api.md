# 创意工坊 v1 数据合同

2026-11-12。**未在真机上验证**，也尚未部署。实现说明见 [workshop-worker.md](../../../docs/design/workshop-worker.md)，App 一侧见 [workshop-app.md](../../../docs/design/workshop-app.md)。

时间戳均由服务器生成，为 UTC ISO-8601。投稿者的 `User-Api-Key` 仅随本次请求发送，不出现在响应或持久记录里。管理员沿用 `X-Admin-Key`。

## 公共查询

`GET /api/workshop/v1/capabilities`：

```json
{"schema":1,"features":{"uploads":true,"companion":true},"kinds":["pet","companion"],"licenses":["CC0-1.0","CC-BY-4.0","CC-BY-SA-4.0","MIT","Apache-2.0","BSD-2-Clause","BSD-3-Clause","LicenseRef-Author-Permission"],"forumOrigin":"https://forum.dshtui.com","maxMocVersion":6,"limits":{"archiveBytes":20971520,"expandedBytes":67108864,"companionMemberBytes":16777216,"companionEntries":1000,"petEntries":256}}
```

`GET|HEAD /market/workshop.json`：

```json
{"schema":1,"generatedAt":"2026-11-11T00:00:00.000Z","features":{"uploads":true,"companion":true},"entries":[{"kind":"pet","id":"sample","version":"1.0.0","minApp":"1.0.13","title":{"zh":"示例","en":"Sample"},"author":"作者","license":"CC0-1.0","source":"https://example.org/sample","url":"/market/workshop/pet/sample/1.0.0/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1234,"blockedVersions":[]}],"withdrawn":[{"kind":"pet","id":"old-sample","version":"1.0.0","reason":"作者撤回","at":"2026-11-11T00:00:00.000Z"}]}
```

`/market/companions.json` 是同一状态的 companion 过滤投影，字段仍为 `entries`，没有独立的发布存储。companion 关闭时，投影及其下载返回 503；主目录仍能浏览 pet，并保留所有种类的 `withdrawn`，以便本地处理已安装内容的撤回。目录支持条件 ETag；安装 / 更新前必须向服务器重新验证目录，不使用失效缓存绕过关闭 / 撤回。

`GET|HEAD /market/workshop/<kind>/<id>/<version>/<sha>.zip` 必须匹配当前公开条目、不可变绑定、未撤回；支持 Range / If-Range。待审 / 拒绝的包即使 SHA 已知也不可从公共接口下载，不跳转裸桶。

## metadata 与投稿记录

```json
{"kind":"pet","id":"sample","version":"1.0.0","minApp":"1.0.13","title":{"zh":"示例","en":"Sample"},"author":"作者","license":"CC0-1.0","source":"https://example.org/sample","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1234,"rightsConfirmed":true}
```

- `id`：小写字母 / 数字，以单个连字符分隔，最多 40 字符。
- `version`：用既有的 `validVersion`（无 build metadata）。
- `source`：必须是 HTTPS 且无用户密码。
- `title`：中英文各最多 120 码点；`author` 最多 256。
- pet 包内的 `id` / `author` / `license` / `source` 必须一致。
- companion 的 `character.json` 必须有 `schema=1`、`name`、`model`、`author` / `license` / `source`；`name` 可为模型原名，`model` 为 character 内相对的 `model3.json`；拒绝 runtime 与 `index.json`（后者由安装器重建）。

所有投稿成功响应为 `{submission: 记录}`。记录形状：

```json
{"submissionId":"0123456789abcdef0123456789abcdef","owner":{"forumOrigin":"https://forum.dshtui.com","forumUserId":42,"username":"sample"},"metadata":{},"status":"draft","createdAt":"2026-11-11T00:00:00.000Z","updatedAt":"2026-11-11T00:00:00.000Z"}
```

`metadata` 是上面的完整对象。`status` 枚举为 draft / pending / approved / rejected / withdrawn。

- pending 增加 `submittedAt` 与 `validation`（`validator`、`files`、`expandedBytes`，以及 `sheets?` 或 `mocVersions?`）。
- approved / rejected 增加 `review: {at, decision, reason}`。
- withdrawn 增加 `withdrawal: {at, reason}`。
- 可选键不存在时省略。

| 请求（前缀 `/api/workshop/v1`） | 请求体 | 成功 |
| --- | --- | --- |
| `POST /submissions` | `{requestId, ...metadata}`；`requestId` 为 16..128 位 ASCII 字母数字 `_-` | 首次 201，同一 `requestId` 且 metadata 一致的重试 200，`{submission}` |
| `PUT /submissions/<id>/archive` | `application/zip` 原始 ZIP | 200 `{submission}`；验证后为 pending；pending 状态下相同字节重试可 200 |
| `GET /submissions?limit=20&cursor=<id>&status=pending` | 无 | 200 `{submissions:[...], nextCursor: null 或 id}`，仅本人；`limit` 默认 20、最大 100，按 id 字典序 |
| `GET /submissions/<id>` | 无 | 200 `{submission}`，仅本人 |
| `POST /submissions/<id>/withdraw` | `{reason}`，1..2000 码点 | 200 `{submission}`；上传关闭时仍允许撤回；已撤回幂等 |
| `POST /reports` | `{kind, id, version, reason}`，`reason` 1..2000 码点 | 201 `{reportId}`；只举报已发布版本，不自动下架 |
| `GET /admin/submissions` | 同列表查询参数 | 200 `{submissions, nextCursor}`，所有作者 |
| `GET` 或 `HEAD /admin/submissions/<id>/archive` | 无 | 200 / 206 私有审核 ZIP，Range 可用 |
| `POST /admin/submissions/<id>/withdraw` | `{reason}`，1..2000 码点 | 200 `{submission}`；管理员可撤回废弃的 draft / pending / rejected 以及已批准版本，保留审计与历史 |
| `POST /admin/submissions/<id>/review` | `{decision: "approve" 或 "reject", reason}`，`reason` 1..2000 码点 | 200 `{submission}`；approve 重验字节后 CAS |
| `GET /admin/reports` | `?limit=20&cursor=<reportId>` | 200 `{reports:[{reportId, kind, id, version, reason, reporter, createdAt}], nextCursor}` |
| `POST /admin/releases/withdraw` | `{kind, id, version, reason}`，`reason` 1..2000 码点 | 200 `{withdrawn:{kind, id, version, reason, at}}` |

公开查询无需身份。创建、上传、本人列表 / 查看、撤回、举报都需要论坛 User API key。外层 UI 先核对 `forumOrigin` 并明确确认将凭据交给这个 Worker；数据层不隐式授权。

## 失败

失败响应固定为 JSON `{error: "workshop_<code>"}`，不含底层异常、论坛正文或凭据。论坛响应过大、格式不符、身份不明时失败关闭。

| HTTP | code（统一加 `workshop_` 前缀） | 含义 |
| --- | --- | --- |
| 400 | `bad_metadata` / `bad_request` / `bad_request_id` / `bad_query` / `bad_reason` / `bad_decision` | 输入无效 |
| 400 | `archive_*` / `json_*` / `pack_*` / `sheet_*` / `png_*` / `inflate_*` / `zlib_*` / `pet_extra_file` / `companion_*` | 包验证失败，未进入待审 |
| 401 | `forum_auth_required` / `forum_auth_invalid` / `admin_auth_required` | 身份失败 |
| 404 | `not_found` | 无记录 / 非本人 / 非公开资源 |
| 405 | `method_not_allowed` | 方法不支持 |
| 409 | `request_id_reused` / `state_conflict` / `submission_state` / `version_rewritten` / `owner_conflict` / `version_withdrawn` | 并发或不可变冲突，GET 重新核对 |
| 413 | `body_too_large` | 大小超限 |
| 415 | `content_type` | 需要 `application/json` 或 `application/zip` |
| 422 | `size_mismatch` / `sha_mismatch` | 字节与 metadata 不同 |
| 429 | `rate_limited` | 限流，带 `Retry-After` |
| 503 | `upload_disabled` / `companion_disabled` | 紧急开关关闭 |
| 503 | `forum_unavailable` / `forum_configuration` / `admin_unavailable` / `storage_unavailable` / `state_invalid` / `capacity` / `moc_policy_unavailable` | 服务或维护错误 |

提交超时不能证明未写入：用同一 `requestId` 重试创建，并 GET 原 submissionId 核对状态。CAS 冲突返回 409，孤立的私有 blob 不会成为已批准。分页是实时视图，不承诺并发写入时的快照一致性。moc 上限 6 来自 2026-11-07 的历史实测，不等于本次的 Core 一致性检查或 GPU / 真机验证。
