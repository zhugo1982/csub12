最新ds
```
curl -sSL https://raw.githubusercontent.com/zhugo1982/csub12/refs/heads/main/ds -o /usr/local/bin/sub && chmod +x /usr/local/bin/sub; sub
```

如果是已经部署过的服务器，要保留现有节点，命令末尾换成 sub refresh
```
curl -sSL https://raw.githubusercontent.com/zhugo1982/csub12/refs/heads/main/ds -o /usr/local/bin/sub && chmod +x /usr/local/bin/sub; sub refresh
```

命令前半段是一样的：把新脚本下载到服务器，替换掉旧的 sub。差别只在末尾：

末尾	效果
; sub	打开菜单，等你自己选
; sub refresh	不进菜单，直接执行「更新订阅 / 追加新功能」，不重置节点

sub refresh 就等于进菜单后手动选 5，两种方式结果一样，后者只是省了一步。

为什么我建议加 refresh

只替换脚本文件，服务器上的实际配置并不会变。新版本带来的服务端改动，比如 ShadowTLS 节点、禁止访问内网的安全规则、新的订阅服务程序，都要等执行了"更新"才会生效。

如果你只用 ; sub，进了菜单却什么都不选就退出，脚本是新的，服务器上却还是旧配置，新功能用不上。

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




在服务器上输入 sub 后面跟一个词，就能直接执行对应功能，不用先进菜单：

命令	作用	对应菜单
sub show	查看所有节点和订阅链接	1
sub refresh	更新订阅、追加新功能，不重置节点	5
sub status	状态检测，哪里不通先跑它	3
sub qr	显示订阅二维码	6
sub bbr	开启 BBR 加速	7
sub traffic	查看流量统计	8
sub port	修改某个协议或订阅服务的端口	11
sub check	只检查有没有新版本，不升级	无
sub upgrade	检查并升级脚本	10

几个小用法：

sub qr 3 可以直接指定二维码类型：1 是通用订阅，2 是 sing-box 全局，3 是 sing-box 分流，4 是 Clash。
sub upgrade -y 跳过确认直接升级。


sub install：全新部署，会重置所有节点凭证。
sub uninstall：彻底卸载。
sub upgrade-core：升级 sing-box 内核（对应菜单 9）。
sub version：显示脚本版本。
