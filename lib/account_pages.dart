import 'package:flutter/material.dart';

import 'models.dart';
import 'share_api.dart';
import 'store.dart';

const _ink = Color(0xFF1E2B27);
const _muted = Color(0xFF6E7C76);
const _canvas = Color(0xFFF4F6F2);
const _teal = Color(0xFF39786B);

void _toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );

/// 内部账号登录。
///
/// 登录接口是 `POST /api/auth/login`，令牌用于「使用提示」编辑与共享模拟配置上传。
class InternalLoginPage extends StatefulWidget {
  const InternalLoginPage({required this.store, super.key});

  final AppStore store;

  @override
  State<InternalLoginPage> createState() => _InternalLoginPageState();
}

class _InternalLoginPageState extends State<InternalLoginPage> {
  late final TextEditingController usernameController;
  late final TextEditingController passwordController;
  bool busy = false;
  String statusText = '未登录';
  String remark = '';

  @override
  void initState() {
    super.initState();
    usernameController = TextEditingController();
    passwordController = TextEditingController();
    _refreshProfile();
  }

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = widget.store.authToken.isNotEmpty;
    return Scaffold(
      backgroundColor: _canvas,
      appBar: AppBar(
        title: const Text(
          '内部账号',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                loggedIn ? Icons.verified_user : Icons.person_off_outlined,
                color: _teal,
              ),
              title: Text(
                loggedIn ? '已登录：${widget.store.accountName}' : statusText,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                loggedIn
                    ? '${widget.store.testerTypeLabel.isEmpty ? '内部账号' : widget.store.testerTypeLabel}${remark.isEmpty ? '' : ' · $remark'}'
                    : '登录后可编辑使用提示、上传共享模拟配置',
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
              trailing: loggedIn
                  ? TextButton(
                      onPressed: busy ? null : _logout,
                      child: const Text('退出'),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              leading: const Icon(Icons.dns_outlined, color: _teal),
              title: const Text('共享服务器'),
              subtitle: Text(
                widget.store.shareBaseUrl.isEmpty
                    ? '未配置，登录前请先填写服务器地址'
                    : widget.store.shareBaseUrl,
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _editServer,
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '登录信息',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: usernameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '设备 ID：${widget.store.deviceId}\n设备名称：${widget.store.deviceName}',
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: busy ? null : _login,
                          icon: busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.login),
                          label: Text(busy ? '登录中' : '登录'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: busy ? null : _refreshProfile,
                        icon: const Icon(Icons.refresh),
                        label: const Text('刷新资料'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '说明：内部账号用于共享服务器的内容维护（使用提示、模拟配置）。'
            '普通下载/上传路线与 NFC 不需要登录。',
            style: TextStyle(fontSize: 12, color: _muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  Future<void> _login() async {
    if (widget.store.shareBaseUrl.isEmpty) {
      _toast(context, '请先填写共享服务器地址');
      return;
    }
    final username = usernameController.text.trim();
    final password = passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      _toast(context, '请输入账号和密码');
      return;
    }
    setState(() => busy = true);
    try {
      final api = ShareApi(widget.store.shareBaseUrl);
      final response = await api.login(
        username,
        password,
        deviceId: widget.store.deviceId.isEmpty
            ? 'flutter-$username'
            : widget.store.deviceId,
        deviceName: widget.store.deviceName.isEmpty
            ? 'RunToolBox Flutter'
            : widget.store.deviceName,
      );
      final token = response['token'] as String? ?? '';
      if (token.isEmpty) {
        throw const FormatException('登录响应没有 token');
      }
      final account = (response['account'] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      final profile = InternalAccountProfile.fromJson(account);
      await widget.store.saveShareSession(
        baseUrl: widget.store.shareBaseUrl,
        token: token,
        account: profile.username.isEmpty ? username : profile.username,
        testerTypeLabel: profile.testerTypeLabel,
      );
      passwordController.clear();
      setState(() {
        statusText = '已登录';
        remark = profile.remark;
      });
      if (mounted) _toast(context, '登录成功');
    } catch (error) {
      if (mounted) _toast(context, '登录失败：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _refreshProfile() async {
    if (widget.store.authToken.isEmpty) return;
    setState(() => busy = true);
    try {
      final profile = await ShareApi(
        widget.store.shareBaseUrl,
        token: widget.store.authToken,
      ).accountProfile();
      await widget.store.saveShareSession(
        baseUrl: widget.store.shareBaseUrl,
        token: widget.store.authToken,
        account: profile.username.isEmpty
            ? widget.store.accountName
            : profile.username,
        testerTypeLabel: profile.testerTypeLabel,
      );
      if (mounted) {
        setState(() {
          statusText = '已登录';
          remark = profile.remark;
        });
      }
    } catch (_) {
      // 后端暂时不可用时保留本地缓存的资料。
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _logout() async {
    await widget.store.clearShareSession();
    if (mounted) {
      setState(() {
        statusText = '未登录';
        remark = '';
      });
      _toast(context, '已退出登录');
    }
  }

  Future<void> _editServer() async {
    final controller = TextEditingController(text: widget.store.shareBaseUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('共享服务器地址'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration:
              const InputDecoration(labelText: '例如 http://10.0.2.2:8000/'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    await widget.store.setShareBaseUrl(value);
    setState(() {});
  }
}
