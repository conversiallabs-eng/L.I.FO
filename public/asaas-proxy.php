<?php
// Proxy IP fixo LIFO -> Asaas.
// A senha NÃO fica neste arquivo: ela mora em asaas-proxy-config.php
// UM NÍVEL ACIMA do public_html (fora da área web e fora do git).
// Veja public/asaas-proxy-config.example.php
$configFile = dirname(__DIR__) . '/asaas-proxy-config.php';
if (is_file($configFile)) { require $configFile; }
if (!defined('PROXY_SECRET') || PROXY_SECRET === '') {
  $envSecret = getenv('ASAAS_PROXY_SECRET');
  if ($envSecret !== false && $envSecret !== '') { define('PROXY_SECRET', $envSecret); }
}
if (!defined('PROXY_SECRET') || PROXY_SECRET === '' || PROXY_SECRET === 'TROQUE-ESTA-SENHA') {
  http_response_code(500);
  header('Content-Type: application/json');
  echo json_encode(['error' => 'proxy nao configurado']);
  exit;
}
const ASAAS_BASE = 'https://api.asaas.com/v3';
const ALLOWED = ['/customers', '/payments'];
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: authorization, x-client-info, apikey, content-type, access_token, access-token, x-proxy-secret');
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
$lower = array();
foreach ($headers_in as $hk => $hv) { $lower[strtolower($hk)] = $hv; }
// Aceita access-token (com traco, atravessa CDN/nginx) ou access_token direto
$token = isset($lower['access-token']) ? $lower['access-token'] : (isset($lower['access_token']) ? $lower['access_token'] : '');
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
