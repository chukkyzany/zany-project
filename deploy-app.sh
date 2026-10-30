#!/bin/bash
# Deploys the eshop PHP app on the Ubuntu EC2 (Apache + PHP already installed by user data).
# Run with: sudo bash /tmp/deploy-app.sh
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo: sudo bash $0"
  exit 1
fi

read -r -p "RDS endpoint: " DB_HOST
read -r -p "DB username [admin]: " DB_USER
DB_USER=${DB_USER:-admin}
read -r -s -p "DB password: " DB_PASS
echo

# --- Private folder (outside the web root) for credentials and the RDS CA bundle ---
mkdir -p /var/www/private
curl -fsS -o /var/www/private/global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

export DB_HOST DB_USER DB_PASS
php -r '$c = ["host" => getenv("DB_HOST"), "user" => getenv("DB_USER"), "pass" => getenv("DB_PASS"), "name" => "eshop"]; echo "<?php\nreturn " . var_export($c, true) . ";\n";' > /var/www/private/config.php

chown -R root:www-data /var/www/private
chmod 750 /var/www/private
chmod 640 /var/www/private/config.php /var/www/private/global-bundle.pem

cd /var/www/html

# --- layout.php: session, helpers, shared header/footer ---
cat > layout.php <<'PHPEOF'
<?php
session_start();

function e($s): string {
    return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8');
}

function cart_count(): int {
    return array_sum($_SESSION['cart'] ?? []);
}

function page_header(string $title): void {
    $n = cart_count();
    echo '<!doctype html><html lang="en"><head><meta charset="utf-8">'
       . '<meta name="viewport" content="width=device-width,initial-scale=1">'
       . '<title>' . e($title) . ' - eshop</title><style>'
       . 'body{font-family:system-ui,sans-serif;margin:0;background:#f6f7f9;color:#1d2433}'
       . 'header{display:flex;justify-content:space-between;align-items:center;padding:14px 24px;background:#1d2433}'
       . 'header a{color:#fff;text-decoration:none;font-weight:600}'
       . 'main{max-width:900px;margin:24px auto;padding:0 16px}'
       . '.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:16px}'
       . '.card{background:#fff;border-radius:10px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.08)}'
       . '.price{font-weight:700;font-size:1.1rem}'
       . 'button{background:#2563eb;color:#fff;border:0;border-radius:6px;padding:8px 14px;cursor:pointer}'
       . 'button.link{background:none;color:#b91c1c;padding:0}'
       . 'table{width:100%;border-collapse:collapse;background:#fff;border-radius:10px;overflow:hidden}'
       . 'th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #eceef2}'
       . 'input{padding:8px;border:1px solid #cbd2dc;border-radius:6px;width:100%;box-sizing:border-box;margin:4px 0 12px}'
       . '.error{background:#fee2e2;color:#991b1b;padding:10px 14px;border-radius:6px;margin-bottom:12px}'
       . 'footer{text-align:center;color:#6b7280;font-size:.8rem;padding:24px}'
       . '</style></head><body><header><a href="index.php">eshop</a>'
       . '<a href="cart.php">Cart (' . $n . ')</a></header><main>';
}

function page_footer(): void {
    echo '</main><footer>Served by ' . e(gethostname()) . '</footer></body></html>';
}
PHPEOF

# --- db.php: PDO connection (verified SSL) and cart helper ---
cat > db.php <<'PHPEOF'
<?php
function db(): PDO {
    static $pdo = null;
    if ($pdo === null) {
        $c = require '/var/www/private/config.php';
        $pdo = new PDO(
            "mysql:host={$c['host']};dbname={$c['name']};charset=utf8mb4",
            $c['user'],
            $c['pass'],
            [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::MYSQL_ATTR_SSL_CA => '/var/www/private/global-bundle.pem',
                PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT => true,
            ]
        );
    }
    return $pdo;
}

function cart_lines(PDO $pdo, array $cart): array {
    if (!$cart) {
        return [];
    }
    $ids = array_keys($cart);
    $in = implode(',', array_fill(0, count($ids), '?'));
    $st = $pdo->prepare("SELECT * FROM products WHERE id IN ($in)");
    $st->execute($ids);
    $lines = [];
    foreach ($st->fetchAll() as $p) {
        $qty = (int)$cart[$p['id']];
        $lines[] = ['p' => $p, 'qty' => $qty, 'sub' => $qty * (float)$p['price']];
    }
    return $lines;
}
PHPEOF

# --- index.php: product list ---
cat > index.php <<'PHPEOF'
<?php
require __DIR__ . '/layout.php';
require __DIR__ . '/db.php';

$products = db()->query('SELECT * FROM products ORDER BY id')->fetchAll();

page_header('Products');
echo '<h1>Products</h1><div class="grid">';
foreach ($products as $p) {
    echo '<div class="card"><h3>' . e($p['name']) . '</h3><p>' . e($p['description']) . '</p>'
       . '<p class="price">$' . number_format((float)$p['price'], 2) . '</p>';
    if ($p['stock'] > 0) {
        echo '<form method="post" action="cart.php">'
           . '<input type="hidden" name="action" value="add">'
           . '<input type="hidden" name="id" value="' . (int)$p['id'] . '">'
           . '<button>Add to cart</button></form>';
    } else {
        echo '<p>Out of stock</p>';
    }
    echo '</div>';
}
echo '</div>';
page_footer();
PHPEOF

# --- cart.php: add / update / remove, session-based cart ---
cat > cart.php <<'PHPEOF'
<?php
require __DIR__ . '/layout.php';
require __DIR__ . '/db.php';

$_SESSION['cart'] = $_SESSION['cart'] ?? [];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $id = (int)($_POST['id'] ?? 0);
    $action = $_POST['action'] ?? '';
    if ($action === 'add' && $id > 0) {
        $_SESSION['cart'][$id] = min(99, ($_SESSION['cart'][$id] ?? 0) + 1);
    } elseif ($action === 'remove') {
        unset($_SESSION['cart'][$id]);
    } elseif ($action === 'update') {
        $q = (int)($_POST['qty'] ?? 0);
        if ($q <= 0) {
            unset($_SESSION['cart'][$id]);
        } else {
            $_SESSION['cart'][$id] = min(99, $q);
        }
    }
    header('Location: cart.php');
    exit;
}

$lines = cart_lines(db(), $_SESSION['cart']);
$total = array_sum(array_column($lines, 'sub'));

page_header('Cart');
echo '<h1>Your cart</h1>';
if (!$lines) {
    echo '<p>Your cart is empty. <a href="index.php">Browse products</a></p>';
} else {
    echo '<table><tr><th>Product</th><th>Price</th><th>Qty</th><th>Subtotal</th><th></th></tr>';
    foreach ($lines as $l) {
        $p = $l['p'];
        echo '<tr><td>' . e($p['name']) . '</td>'
           . '<td>$' . number_format((float)$p['price'], 2) . '</td>'
           . '<td><form method="post" style="display:flex;gap:6px">'
           . '<input type="hidden" name="action" value="update">'
           . '<input type="hidden" name="id" value="' . (int)$p['id'] . '">'
           . '<input type="number" name="qty" min="0" max="99" value="' . $l['qty'] . '" style="width:70px;margin:0">'
           . '<button>Update</button></form></td>'
           . '<td>$' . number_format($l['sub'], 2) . '</td>'
           . '<td><form method="post"><input type="hidden" name="action" value="remove">'
           . '<input type="hidden" name="id" value="' . (int)$p['id'] . '">'
           . '<button class="link">Remove</button></form></td></tr>';
    }
    echo '</table><p class="price">Total: $' . number_format($total, 2) . '</p>'
       . '<p><a href="checkout.php"><button>Checkout</button></a></p>';
}
PHPEOF


# --- checkout.php: guest checkout, stored in a transaction ---

cat > checkout.php <<'PHPEOF'

<?php

require __DIR__ . '/layout.php';
require __DIR__ . '/db.php';

$cart = $_SESSION['cart'] ?? [];
if (!$cart) {
    header('Location: index.php');
    exit;
}


$pdo = db();
$error = '';
$name = '';
$email = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $name = trim($_POST['name'] ?? '');
    $email = trim($_POST['email'] ?? '');

    if ($name === '' || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
        $error = 'Please enter your name and a valid email address.';
    } else {
        try {
            $pdo->beginTransaction();
            $total = 0.0;
            $items = [];
            foreach ($cart as $pid => $qty) {
                $st = $pdo->prepare('SELECT id, name, price, stock FROM products WHERE id = ? FOR UPDATE');
                $st->execute([(int)$pid]);
                $p = $st->fetch();
                if (!$p) {
                    throw new RuntimeException('A product in your cart is no longer available.');
                }
                if ($p['stock'] < $qty) {
                    throw new RuntimeException('Not enough stock for ' . $p['name'] . '.');
                }
                $total += $qty * (float)$p['price'];
                $items[] = [$p, (int)$qty];
            }

            $pdo->prepare('INSERT INTO orders (customer_name, customer_email, total) VALUES (?, ?, ?)')
                ->execute([$name, $email, $total]);
            $orderId = (int)$pdo->lastInsertId();

            foreach ($items as [$p, $qty]) {
                $pdo->prepare('INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (?, ?, ?, ?)')
                    ->execute([$orderId, $p['id'], $qty, $p['price']]);
                $pdo->prepare('UPDATE products SET stock = stock - ? WHERE id = ?')
                    ->execute([$qty, $p['id']]);
            }

            $pdo->commit();
            $_SESSION['cart'] = [];
            header('Location: success.php?id=' . $orderId);
            exit;
        } catch (RuntimeException $ex) {
            $pdo->rollBack();
            $error = $ex->getMessage();
        } catch (Throwable $ex) {
            if ($pdo->inTransaction()) {
                $pdo->rollBack();
            }
            error_log('checkout failed: ' . $ex->getMessage());
            $error = 'Something went wrong. Please try again.';
        }
    }
}

$lines = cart_lines($pdo, $cart);
$total = array_sum(array_column($lines, 'sub'));

page_header('Checkout');
echo '<h1>Checkout</h1>';
if ($error) {
    echo '<div class="error">' . e($error) . '</div>';
}
echo '<table><tr><th>Product</th><th>Qty</th><th>Subtotal</th></tr>';
foreach ($lines as $l) {
    echo '<tr><td>' . e($l['p']['name']) . '</td><td>' . $l['qty'] . '</td>'
       . '<td>$' . number_format($l['sub'], 2) . '</td></tr>';
}
echo '</table><p class="price">Total: $' . number_format($total, 2) . '</p>'
   . '<form method="post"><label>Name<input name="name" value="' . e($name) . '" required></label>'
   . '<label>Email<input type="email" name="email" value="' . e($email) . '" required></label>'
   . '<button>Place order</button></form>';
page_footer();
PHPEOF

# --- success.php: order confirmation (no personal details shown) ---
cat > success.php <<'PHPEOF'
<?php
require __DIR__ . '/layout.php';
require __DIR__ . '/db.php';

$id = (int)($_GET['id'] ?? 0);
$st = db()->prepare('SELECT id, total FROM orders WHERE id = ?');
$st->execute([$id]);
$order = $st->fetch();

page_header('Order confirmed');
if ($order) {
    echo '<h1>Thank you!</h1><p>Your order <strong>#' . (int)$order['id'] . '</strong> has been placed.</p>'
       . '<p class="price">Total: $' . number_format((float)$order['total'], 2) . '</p>'
       . '<p><a href="index.php">Continue shopping</a></p>';
} else {
    echo '<h1>Order not found</h1><p><a href="index.php">Back to products</a></p>';
}
page_footer();
PHPEOF

chown -R www-data:www-data /var/www/html
systemctl restart apache2

echo
echo "Done. Test locally with:  curl -s localhost/index.php | head -n 20"

