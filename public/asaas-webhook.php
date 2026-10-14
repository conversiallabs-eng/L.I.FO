<?php
// Webhook Asaas -> LIFO. Asaas chama esta URL quando o PIX confirma.
// URL no painel Asaas: https://lifo.com.br/asaas-webhook.php
// Eventos: PAYMENT_CONFIRMED, PAYMENT_RECEIVED
// Segredos (ASAAS_WEBHOOK_TOKEN, ASAAS_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_KEY)
// moram em asaas-proxy-config.php UM NIVEL ACIMA do public_html.
header("Content-Type: application/json");
$configFile = dirname(__DIR__) . "/asaas-proxy-config.php";
if (is_file($configFile)) { require $configFile; }
$tokenOk = defined("ASAAS_WEBHOOK_TOKEN") && ASAAS_WEBHOOK_TOKEN !== "";
$got = isset($_SERVER["HTTP_ASAAS_TOKEN"]) ? $_SERVER["HTTP_ASAAS_TOKEN"] : (isset($_GET["token"]) ? $_GET["token"] : "");
if (!$tokenOk || !hash_equals(ASAAS_WEBHOOK_TOKEN, (string)$got)) {
  http_response_code(403);
  echo json_encode(array("error" => "webhook unauthorized"));
  exit;
}
$raw = file_get_contents("php://input");
$event = json_decode($raw, true);
if (!is_array($event)) { http_response_code(400); echo json_encode(array("error" => "json invalido")); exit; }
$evName = isset($event["event"]) ? $event["event"] : "";
$payment = isset($event["payment"]) ? $event["payment"] : array();
$payStatus = isset($payment["status"]) ? strtoupper((string)$payment["status"]) : "";
$confirmed = ($evName === "PAYMENT_CONFIRMED" || $evName === "PAYMENT_RECEIVED")
  || ($evName === "PAYMENT_UPDATED" && ($payStatus === "RECEIVED" || $payStatus === "CONFIRMED" || $payStatus === "RECEIVED_IN_CASH"));
if (!$confirmed) { echo json_encode(array("ok" => true, "ignored" => $evName)); exit; }
if (!defined("ASAAS_API_KEY") || !defined("SUPABASE_URL") || !defined("SUPABASE_SERVICE_KEY")) {
  http_response_code(500);
  echo json_encode(array("error" => "webhook sem configuracao"));
  exit;
}

$customerId = isset($payment["customer"]) ? $payment["customer"] : "";
$payValue = isset($payment["value"]) ? $payment["value"] : 19.90;
$payId = isset($payment["id"]) ? $payment["id"] : "";
// Busca o e-mail do cliente no Asaas (sai pelo IP fixo, ja whitelistado)
$email = "";
if ($customerId !== "") {
  $ch = curl_init("https://api.asaas.com/v3/customers/" . urlencode($customerId));
  curl_setopt_array($ch, array(
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTPHEADER => array("Content-Type: application/json", "access_token: " . ASAAS_API_KEY, "User-Agent: LIFO-Logistica-App/1.0"),
    CURLOPT_TIMEOUT => 20,
  ));
  $cbody = curl_exec($ch);
  curl_close($ch);
  $cdata = json_decode((string)$cbody, true);
  if (is_array($cdata) && isset($cdata["email"])) { $email = $cdata["email"]; }
}
if ($email === "") { http_response_code(200); echo json_encode(array("ok" => true, "warn" => "sem email")); exit; }
// Localiza o usuario no Supabase pelo e-mail
$sbUrl = rtrim(SUPABASE_URL, "/");
$sbKey = SUPABASE_SERVICE_KEY;
function sbReq($method, $url, $key, $bodyArr = null) {
  $ch = curl_init($url);
  $headers = array("apikey: " . $key, "Authorization: Bearer " . $key, "Content-Type: application/json");
  $opts = array(CURLOPT_RETURNTRANSFER => true, CURLOPT_CUSTOMREQUEST => $method, CURLOPT_HTTPHEADER => $headers, CURLOPT_TIMEOUT => 20);
  if ($bodyArr !== null) { $opts[CURLOPT_POSTFIELDS] = json_encode($bodyArr); }
  curl_setopt_array($ch, $opts);
  $b = curl_exec($ch);
  $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
  curl_close($ch);
  return array($code, json_decode((string)$b, true));
}
list($uc, $users) = sbReq("GET", $sbUrl . "/rest/v1/user_profiles?email=eq." . urlencode($email) . "&select=id", $sbKey);
$userId = (is_array($users) && isset($users[0]["id"])) ? $users[0]["id"] : "";
if ($userId === "") { http_response_code(200); echo json_encode(array("ok" => true, "warn" => "usuario nao achado")); exit; }
$starts = date("c");
$expires = date("c", time() + 30 * 24 * 3600);
$row = array(
  "user_id" => $userId,
  "plan_type" => "pix_manual",
  "status" => "active",
  "price_cents" => (int)round(((float)$payValue) * 100),
  "starts_at" => $starts,
  "expires_at" => $expires,
  "updated_at" => $starts,
  "external_provider_id" => $payId,
);
// Atualiza se ja existe assinatura, senao insere
list($gc, $subs) = sbReq("GET", $sbUrl . "/rest/v1/subscriptions?user_id=eq." . urlencode($userId) . "&select=id&limit=1", $sbKey);
if (is_array($subs) && count($subs) > 0) {
  $sid = $subs[0]["id"];
  list($code, $resp) = sbReq("PATCH", $sbUrl . "/rest/v1/subscriptions?id=eq." . urlencode($sid), $sbKey, $row);
} else {
  list($code, $resp) = sbReq("POST", $sbUrl . "/rest/v1/subscriptions", $sbKey, $row);
}
http_response_code(200);
echo json_encode(array("ok" => true, "user" => $userId, "http" => $code));
