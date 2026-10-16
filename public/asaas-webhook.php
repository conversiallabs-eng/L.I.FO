<?php
// Webhook Asaas -> LIFO.
// O Asaas dispara este webhook quando uma cobrança PIX é confirmada/recebida.
// URL configurada no Asaas: https://lifo.com.br/asaas-webhook.php
//
// Segredos moram em asaas-proxy-config.php UM NÍVEL ACIMA do public_html:
//   domains/lifo.com.br/asaas-proxy-config.php
//   (PROXY_SECRET, ASAAS_WEBHOOK_TOKEN, ASAAS_API_KEY, SUPABASE_URL, SUPABASE_SERVICE_KEY)

header("Content-Type: application/json");

$configFile = dirname(__DIR__) . "/asaas-proxy-config.php";
if (is_file($configFile)) {
    require $configFile;
}

// 1. Autenticação do Webhook
$headers_in = function_exists('getallheaders') ? getallheaders() : array();
$lower = array();
foreach ($headers_in as $hk => $hv) {
    $lower[strtolower($hk)] = $hv;
}

$gotToken = isset($lower['asaas-access-token']) ? $lower['asaas-access-token'] :
            (isset($_SERVER['HTTP_ASAAS_ACCESS_TOKEN']) ? $_SERVER['HTTP_ASAAS_ACCESS_TOKEN'] :
            (isset($_GET['token']) ? $_GET['token'] : ''));

$gotSecret = isset($lower['x-proxy-secret']) ? $lower['x-proxy-secret'] :
             (isset($_SERVER['HTTP_X_PROXY_SECRET']) ? $_SERVER['HTTP_X_PROXY_SECRET'] :
             (isset($_GET['secret']) ? $_GET['secret'] : ''));

// Se passar a senha do proxy (ex: reprocessamento manual), autoriza direto
$isMasterAuth = defined('PROXY_SECRET') && PROXY_SECRET !== '' && hash_equals(PROXY_SECRET, (string)$gotSecret);

if (!$isMasterAuth) {
    if (defined('ASAAS_WEBHOOK_TOKEN') && ASAAS_WEBHOOK_TOKEN !== '') {
        if (!hash_equals(ASAAS_WEBHOOK_TOKEN, (string)$gotToken)) {
            http_response_code(403);
            echo json_encode(array("error" => "webhook unauthorized", "hint" => "invalid token"));
            exit;
        }
    }
}

// 2. Leitura do JSON enviado pelo Asaas
$raw = file_get_contents("php://input");
$event = json_decode($raw, true);
if (!is_array($event)) {
    http_response_code(400);
    echo json_encode(array("error" => "json invalido"));
    exit;
}

$evName = isset($event["event"]) ? strtoupper((string)$event["event"]) : "";
$payment = isset($event["payment"]) ? $event["payment"] : array();
$payStatus = isset($payment["status"]) ? strtoupper((string)$payment["status"]) : "";

$isConfirmed = ($evName === "PAYMENT_CONFIRMED" || $evName === "PAYMENT_RECEIVED" || $evName === "PAYMENT_RECEIVED_IN_CASH")
    || ($evName === "PAYMENT_UPDATED" && ($payStatus === "RECEIVED" || $payStatus === "CONFIRMED" || $payStatus === "RECEIVED_IN_CASH"));

if (!$isConfirmed) {
    http_response_code(200);
    echo json_encode(array("ok" => true, "ignored" => $evName, "status" => $payStatus));
    exit;
}

if (!defined("SUPABASE_URL") || !defined("SUPABASE_SERVICE_KEY")) {
    http_response_code(500);
    echo json_encode(array("error" => "webhook sem configuracao do Supabase"));
    exit;
}

$payId = isset($payment["id"]) ? (string)$payment["id"] : "";
$payValue = isset($payment["value"]) ? (float)$payment["value"] : 19.90;
$priceCents = (int)round($payValue * 100);

// 3. Localização do auth_uid do usuário
// O app envia o auth_uid no externalReference ao criar a cobrança PIX
$authUid = isset($payment["externalReference"]) ? trim((string)$payment["externalReference"]) : "";

// Fallback: se externalReference não veio, busca e-mail do cliente no Asaas
if ($authUid === "" && isset($payment["customer"]) && (string)$payment["customer"] !== "" && defined("ASAAS_API_KEY")) {
    $ch = curl_init("https://api.asaas.com/v3/customers/" . urlencode((string)$payment["customer"]));
    curl_setopt_array($ch, array(
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => array(
            "Content-Type: application/json",
            "access_token: " . ASAAS_API_KEY,
            "User-Agent: LIFO-Logistica-App/1.0"
        ),
        CURLOPT_TIMEOUT => 20,
    ));
    $cbody = curl_exec($ch);
    curl_close($ch);
    $cdata = json_decode((string)$cbody, true);
    $customerEmail = (is_array($cdata) && isset($cdata["email"])) ? strtolower(trim((string)$cdata["email"])) : "";

    if ($customerEmail !== "") {
        // Busca auth_uid no user_profiles pelo email
        $sbUrl = rtrim(SUPABASE_URL, "/");
        $ch2 = curl_init($sbUrl . "/rest/v1/user_profiles?email=eq." . urlencode($customerEmail) . "&select=auth_uid&limit=1");
        curl_setopt_array($ch2, array(
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => array(
                "apikey: " . SUPABASE_SERVICE_KEY,
                "Authorization: Bearer " . SUPABASE_SERVICE_KEY,
                "Content-Type: application/json"
            ),
            CURLOPT_TIMEOUT => 20,
        ));
        $uBody = curl_exec($ch2);
        curl_close($ch2);
        $uData = json_decode((string)$uBody, true);
        if (is_array($uData) && isset($uData[0]["auth_uid"])) {
            $authUid = (string)$uData[0]["auth_uid"];
        }
    }
}

if ($authUid === "") {
    http_response_code(200);
    echo json_encode(array("ok" => true, "warn" => "usuario nao identificado no pagamento", "payment_id" => $payId));
    exit;
}

// 4. Executa a função canônica fn_apply_payment no Supabase (escritor único idempotente)
$sbUrl = rtrim(SUPABASE_URL, "/");
$rpcUrl = $sbUrl . "/rest/v1/rpc/fn_apply_payment";

$rpcBody = array(
    "p_asaas_payment_id" => $payId,
    "p_user_id" => $authUid,
    "p_value_cents" => $priceCents,
    "p_source" => "webhook",
    "p_provisional_granted_at" => null
);

$ch = curl_init($rpcUrl);
curl_setopt_array($ch, array(
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => json_encode($rpcBody),
    CURLOPT_HTTPHEADER => array(
        "apikey: " . SUPABASE_SERVICE_KEY,
        "Authorization: Bearer " . SUPABASE_SERVICE_KEY,
        "Content-Type: application/json",
        "Prefer: return=representation"
    ),
    CURLOPT_TIMEOUT => 25,
));
$resBody = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

$result = json_decode((string)$resBody, true);

http_response_code(200);
echo json_encode(array(
    "ok" => true,
    "http_code" => $httpCode,
    "user_id" => $authUid,
    "payment_id" => $payId,
    "result" => $result
));
