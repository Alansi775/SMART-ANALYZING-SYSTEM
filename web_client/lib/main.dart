// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const ClientPage(),
    );
  }
}

class ClientPage extends StatefulWidget {
  const ClientPage({super.key});
  @override
  State<ClientPage> createState() => _ClientPageState();
}

class _ClientPageState extends State<ClientPage> {
  web.WebSocket? _socket;
  bool _connected = false;
  bool _streamReady = false;
  String _status = 'Press Start to connect';
  final String serverUrl = 'ws://localhost:3000';

  Future<void> _start() async {
    setState(() => _status = 'Requesting screen permission...');

    // نطلب الإذن أولاً من تفاعل المستخدم
    try {
      await _initScreenCapture();
    } catch (e) {
      setState(() => _status = 'Permission denied: $e');
      return;
    }

    setState(() => _status = 'Connecting to server...');

    _socket = web.WebSocket(serverUrl);

    _socket!.addEventListener('open', (web.Event e) {
      setState(() {
        _connected = true;
        _status = 'Connected - Waiting for commands';
      });
    }.toJS);

    _socket!.addEventListener('message', (web.MessageEvent e) {
      final msg = jsonDecode(e.data.toString());
      if (msg['type'] == 'capture') {
        _captureScreen();
      }
    }.toJS);

    _socket!.addEventListener('close', (web.Event e) {
      setState(() {
        _connected = false;
        _status = 'Disconnected';
      });
    }.toJS);
  }

  Future<void> _initScreenCapture() async {
    // نشغل JS لطلب الإذن وحفظ الـ stream
    web.window.callMethod('eval'.toJS, [
      '''
      (async () => {
        try {
          const stream = await navigator.mediaDevices.getDisplayMedia({ video: true });
          window._captureStream = stream;
          window._streamReady = true;
          console.log('Screen capture ready');
        } catch(e) {
          window._streamError = e.toString();
          console.log('Error:', e);
        }
      })();
      '''.toJS
    ].toJS);

    // ننتظر الإذن
    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 300));
      final ready = web.window.getProperty('_streamReady'.toJS);
      final error = web.window.getProperty('_streamError'.toJS);
      if (error.toString() != 'null' && error.toString().isNotEmpty) {
        throw Exception(error.toString());
      }
      return ready.toString() != 'true';
    }).timeout(const Duration(seconds: 30));

    setState(() => _streamReady = true);
  }

  void _captureScreen() {
    setState(() => _status = 'Capturing...');

    web.window.callMethod('eval'.toJS, [
      '''
      (async () => {
        try {
          const stream = window._captureStream;
          const track = stream.getVideoTracks()[0];
          const video = document.createElement('video');
          video.srcObject = stream;
          await video.play();
          const canvas = document.createElement('canvas');
          canvas.width = video.videoWidth;
          canvas.height = video.videoHeight;
          canvas.getContext('2d').drawImage(video, 0, 0);
          const base64 = canvas.toDataURL('image/jpeg', 0.7);
          window._lastCapture = base64;
          window._captureReady = true;
        } catch(e) {
          window._captureError = e.toString();
        }
      })();
      '''.toJS
    ].toJS);

    Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 300));
      final ready = web.window.getProperty('_captureReady'.toJS);
      final error = web.window.getProperty('_captureError'.toJS);

      if (error.toString() != 'null' && error.toString().isNotEmpty) {
        setState(() => _status = 'Capture error: $error');
        return false;
      }

      if (ready.toString() == 'true') {
        final base64 = web.window.getProperty('_lastCapture'.toJS).toString();
        _socket!.send(jsonEncode({'type': 'screenshot', 'image': base64}).toJS);
        web.window.setProperty('_captureReady'.toJS, false.toJS);
        setState(() => _status = 'Screenshot sent!');
        return false;
      }
      return true;
    });
  }

  void _stop() {
    web.window.callMethod('eval'.toJS, [
      '''
      if (window._captureStream) {
        window._captureStream.getTracks().forEach(t => t.stop());
        window._captureStream = null;
        window._streamReady = false;
      }
      '''.toJS
    ].toJS);
    _socket?.close();
    setState(() {
      _connected = false;
      _streamReady = false;
      _status = 'Stopped';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _connected ? Icons.circle : Icons.circle_outlined,
              color: _connected ? Colors.green : Colors.grey,
              size: 20,
            ),
            const SizedBox(height: 20),
            Text(
              _status,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 40),
            if (!_connected)
              ElevatedButton(
                onPressed: _start,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                ),
                child: const Text('Start'),
              )
            else
              ElevatedButton(
                onPressed: _stop,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                ),
                child: const Text('Stop'),
              ),
          ],
        ),
      ),
    );
  }
}