<?php
const PROXY_SECRET = 'Tatananog12#';
const ASAAS_BASE = 'https://api.asaas.com/v3';
const ALLOWED = ['/customers', '/payments'];
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: authorization, x-client-info, apikey, content-type, access_token, x-proxy-secret');
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') { http_response_code(200); exit; }
$secret = isset($_SERVER['HTTP_X_PROXY_SECRET']) ? $_SERVER['HTTP_X_PROXY_SECRET'] : '';
if ($secret !== PROXY_SECRET) { http_response_code(403); echo json_encode(['error' => 'proxy unauthorized']); exit; }
$raw = isset($_GET['path']) ? $_GET['path'] : '/';
$parts = explode('?', $raw, 2);
$path = $parts[0];
$qs = isset($parts[1]) ? $parts[1] : '';
foreach ($_GET as $k => $v) { if ($k !== 'path') $qs .= ($qs ? '&' : '') . urlencode($k) . '=' . urlencode($v); }
$ok = false;
foreach (ALLOWED as $a) { if (strpos($path, $a) === 0) { $ok = true; break; } }
if (!$ok) { http_response_code(400); echo json_encode(['error' => 'path bloqueado']); exit; }
$target = ASAAS_BASE . $path . ($qs ? "?$qs" : '');
$headers_in = function_exists('getallheaders') ? getallheaders() : array();
$token = isset($headers_in['access_token']) ? $headers_in['access_token'] : (isset($headers_in['Access_token']) ? $headers_in['Access_token'] : '');
$ch = curl_init($target);
curl_setopt_array($ch, array(
  CURLOPT_RETURNTRANSFER => true,
  CURLOPT_CUSTOMREQUEST => $_SERVER['REQUEST_METHOD'],
  CURLOPT_POSTFIELDS => file_get_contents('php://input') ?: null,
  CURLOPT_HTTPHEADER => array('Content-Type: application/json', 'access_token: ' . $token, 'User-Agent: LIFO-Logistica-App/1.0'),
  CURLOPT_TIMEOUT => 25,
));
$body = curl_exec($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);
http_response_code($code ? $code : 502);
echo $body;
