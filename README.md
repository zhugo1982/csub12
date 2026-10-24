最新ds
```
curl -sSL https://raw.githubusercontent.com/zhugo1982/csub12/refs/heads/main/ds -o /usr/local/bin/sub && chmod +x /usr/local/bin/sub; sub
```

```
curl -sSL https://raw.githubusercontent.com/zhugo1982/csub12/refs/heads/main/cs -o /usr/local/bin/sub && chmod +x /usr/local/bin/sub; sub
```





```
curl -sSL https://raw.githubusercontent.com/zhugo1982/csub12/refs/heads/main/s -o /usr/local/bin/sub && chmod +x /usr/local/bin/sub; sub
```
如果是已经部署过的服务器，要保留现有节点，命令末尾换成 sub refresh
```
curl -sSL https://raw.githubusercontent.com/zhugo1982/csub12/refs/heads/main/s -o /usr/local/bin/sub && chmod +x /usr/local/bin/sub; sub refresh
```

```
运行 sub，选 11（或直接 sub port）。会列出 12 个协议和订阅服务的当前端口，选一个编号，输入新端口。脚本会自动做这些事：

检查新端口是否合法，有没有被其他协议、订阅服务或系统程序占用。
修改服务端配置，检查并重启 sing-box，失败自动回滚。
重新生成全部订阅：节点链接、通用订阅、sing-box 两个订阅、Clash。
开放新端口的系统防火墙，关闭旧端口（旧端口没被别的协议用的话）。

节点凭证不变，手机上只需要更新订阅。

这次的几处改动
节点链接改成能从配置重新生成了。 以前是部署时一次性拼好的，现在每次从 singbox.json 读取端口和凭证重新生成。Clash 订阅和防火墙放行的端口也跟着配置走，不再写死。
订阅服务端口可以改（编号 13），但改完所有订阅链接都会变，脚本会提示。
你要留意的
改完要在云安全组放行新端口。 系统防火墙脚本能管，云平台的管不了。
名字不会跟着变。 比如第 3 个节点叫 Hugo-XTLS-Reality-8881，端口改了名字还是 8881，只是个标签，不影响使用。
选 2（全新部署）会把所有协议端口重置回默认值。
