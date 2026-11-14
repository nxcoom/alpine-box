#!/usr/bin/env node
// ============================================================
//  easynode-set-creds — 从环境变量设置 EasyNode 管理员账号 (幂等)
//  由 alpine-box entrypoint 在 EasyNode 启动后调用。
//  必须以 /opt/easynode 为 cwd 运行 (nedb 从其 node_modules 解析,
//  数据库目录 = cwd/app/db)。
//
//  环境变量: EASYNODE_ADMIN_USER / EASYNODE_ADMIN_PASSWORD
//  逻辑与上游 scripts/reset-password.js 一致:
//    key.db: { user, pwd: sha1(password), jwtToken }, 并吊销全部会话。
//    若账号密码已与目标一致则跳过 (不吊销会话)。
// ============================================================
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import Datastore from '@seald-io/nedb'

const DB_DIR = path.join(process.cwd(), 'app/db')
const user = process.env.EASYNODE_ADMIN_USER || ''
const password = process.env.EASYNODE_ADMIN_PASSWORD || ''

if (!user || !password) {
  console.error('EASYNODE_ADMIN_USER / EASYNODE_ADMIN_PASSWORD 未设置')
  process.exit(2)
}

const keyDBPath = path.join(DB_DIR, 'key.db')
if (!fs.existsSync(keyDBPath)) {
  console.error(`key.db 尚未生成: ${keyDBPath}`)
  process.exit(3)
}

const keyDB = new Datastore({ filename: keyDBPath })
await keyDB.loadDatabaseAsync()
const doc = await keyDB.findOneAsync({})
if (!doc?._id) {
  console.error('key.db 中没有管理员记录')
  process.exit(3)
}

const pwdHash = crypto.createHash('sha1').update(password).digest('hex')
if (doc.user === user && doc.pwd === pwdHash) {
  console.log('credentials already set')
  process.exit(0)
}

const jwtToken = crypto.randomBytes(16).toString('hex')
const sessionDBPath = path.join(DB_DIR, 'session.db')
if (fs.existsSync(sessionDBPath)) {
  const sessionDB = new Datastore({ filename: sessionDBPath })
  await sessionDB.loadDatabaseAsync()
  await sessionDB.updateAsync({}, { $set: { revoked: true } }, { multi: true })
}

await keyDB.updateAsync(
  { _id: doc._id },
  { $set: { user, pwd: pwdHash, jwtToken } }
)
console.log('credentials updated')
