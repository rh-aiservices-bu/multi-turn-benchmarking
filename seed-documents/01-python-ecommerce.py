import json
import hashlib
import logging
import asyncio
from datetime import datetime, timedelta
from typing import List, Dict, Optional, Any, Union
from dataclasses import dataclass, field
from enum import Enum
from decimal import Decimal, ROUND_HALF_UP
from collections import defaultdict
import re
from abc import ABC, abstractmethod

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class OrderStatus(Enum):
    PENDING = "pending"
    CONFIRMED = "confirmed"
    PROCESSING = "processing"
    SHIPPED = "shipped"
    DELIVERED = "delivered"
    CANCELLED = "cancelled"
    REFUNDED = "refunded"


class PaymentMethod(Enum):
    CREDIT_CARD = "credit_card"
    DEBIT_CARD = "debit_card"
    PAYPAL = "paypal"
    BANK_TRANSFER = "bank_transfer"
    CRYPTO = "crypto"


class ShippingMethod(Enum):
    STANDARD = "standard"
    EXPRESS = "express"
    OVERNIGHT = "overnight"
    PICKUP = "pickup"


@dataclass
class Address:
    street: str
    city: str
    state: str
    postal_code: str
    country: str
    apartment: Optional[str] = None

    def validate(self) -> bool:
        if not self.street or len(self.street) < 5:
            return False
        if not self.city or len(self.city) < 2:
            return False
        if not self.postal_code:
            return False
        return True

    def format_for_shipping(self) -> str:
        lines = [self.street]
        if self.apartment:
            lines.append(f"Apt {self.apartment}")
        lines.append(f"{self.city}, {self.state} {self.postal_code}")
        lines.append(self.country)
        return "\n".join(lines)


@dataclass
class Product:
    id: str
    name: str
    description: str
    price: Decimal
    stock_quantity: int
    category: str
    weight_kg: float
    dimensions: Dict[str, float]
    is_active: bool = True
    discount_percent: float = 0.0
    tags: List[str] = field(default_factory=list)
    created_at: datetime = field(default_factory=datetime.now)

    def get_discounted_price(self) -> Decimal:
        if self.discount_percent > 0:
            discount = self.price * Decimal(str(self.discount_percent / 100))
            return (self.price - discount).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)
        return self.price

    def is_available(self, quantity: int = 1) -> bool:
        return self.is_active and self.stock_quantity >= quantity

    def reserve_stock(self, quantity: int) -> bool:
        if self.is_available(quantity):
            self.stock_quantity =- quantity
            return True
        return False

    def release_stock(self, quantity: int) -> None:
        self.stock_quantity += quantity


@dataclass
class CartItem:
    product: Product
    quantity: int
    added_at: datetime = field(default_factory=datetime.now)

    def get_subtotal(self) -> Decimal:
        return self.product.get_discounted_price() * self.quantity

    def get_weight(self) -> float:
        return self.product.weight_kg * self.quantity


@dataclass
class Customer:
    id: str
    email: str
    first_name: str
    last_name: str
    phone: Optional[str] = None
    shipping_addresses: List[Address] = field(default_factory=list)
    billing_address: Optional[Address] = None
    is_verified: bool = False
    loyalty_points: int = 0
    created_at: datetime = field(default_factory=datetime.now)
    preferences: Dict[str, Any] = field(default_factory=dict)

    @property
    def full_name(self) -> str:
        return f"{self.first_name} {self.last_name}"

    def validate_email(self) -> bool:
        pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        return re.match(pattern, self.email) is not None

    def add_loyalty_points(self, points: int) -> None:
        self.loyalty_points += points

    def redeem_loyalty_points(self, points: int) -> bool:
        if self.loyalty_points >= points:
            self.loyalty_points -= points
            return True
        return False

    def get_default_shipping_address(self) -> Optional[Address]:
        if self.shipping_addresses:
            return self.shipping_addresses[0]
        return None


class ShoppingCart:
    def __init__(self, customer: Customer):
        self.customer = customer
        self.items: Dict[str, CartItem] = {}
        self.applied_coupons: List[str] = []
        self.created_at = datetime.now()
        self.updated_at = datetime.now()

    def add_item(self, product: Product, quantity: int = 1) -> bool:
        if not product.is_available(quantity):
            logger.warning(f"Product {product.id} not available in requested quantity")
            return False

        if product.id in self.items:
            existing_item = self.items[product.id]
            new_quantity = existing_item.quantity + quantity
            if not product.is_available(new_quantity):
                return False
            existing_item.quantity = new_quantity
        else:
            self.items[product.id] = CartItem(product=product, quantity=quantity)

        self.updated_at = datetime.now()
        return True

    def remove_item(self, product_id: str) -> bool:
        if product_id in self.items:
            del self.items[product_id]
            self.updated_at = datetime.now()
            return True
        return False

    def update_quantity(self, product_id: str, quantity: int) -> bool:
        if product_id not in self.items:
            return False

        if quantity <= 0:
            return self.remove_item(product_id)

        item = self.items[product_id]
        if not item.product.is_available(quantity):
            return False

        item.quantity = quantity
        self.updated_at = datetime.now()
        return True

    def get_subtotal(self) -> Decimal:
        total = Decimal('0.00')
        for item in self.items.values():
            total += item.get_subtotal()
        return total

    def get_total_weight(self) -> float:
        return sum(item.get_weight() for item in self.items.values())

    def get_item_count(self) -> int:
        return sum(item.quantity for item in self.items.values())

    def clear(self) -> None:
        self.items.clear()
        self.applied_coupons.clear()
        self.updated_at = datetime.now()

    def is_empty(self) -> bool:
        return len(self.items) == 0

    def apply_coupon(self, coupon_code: str) -> bool:
        if coupon_code not in self.applied_coupons:
            self.applied_coupons.append(coupon_code)
            return True
        return False


class TaxCalculator:
    TAX_RATES = {
        'US': {
            'CA': 0.0725,
            'NY': 0.08,
            'TX': 0.0625,
            'FL': 0.06,
            'default': 0.05
        },
        'CA': {'default': 0.13},
        'UK': {'default': 0.20},
        'DE': {'default': 0.19},
        'default': 0.10
    }

    @classmethod
    def calculate_tax(cls, subtotal: Decimal, address: Address) -> Decimal:
        country_rates = cls.TAX_RATES.get(address.country, cls.TAX_RATES['default'])

        if isinstance(country_rates, dict):
            rate = country_rates.get(address.state, country_rates.get('default', 0.10))
        else:
            rate = country_rates

        tax = subtotal * Decimal(str(rate))
        return tax.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)


class ShippingCalculator:
    BASE_RATES = {
        ShippingMethod.STANDARD: Decimal('5.99'),
        ShippingMethod.EXPRESS: Decimal('12.99'),
        ShippingMethod.OVERNIGHT: Decimal('24.99'),
        ShippingMethod.PICKUP: Decimal('0.00')
    }

    WEIGHT_RATE = Decimal('0.50')  # per kg
    FREE_SHIPPING_THRESHOLD = Decimal('75.00')

    @classmethod
    def calculate_shipping(
        cls,
        method: ShippingMethod,
        weight_kg: float,
        subtotal: Decimal,
        destination: Address
    ) -> Decimal:
        if method == ShippingMethod.PICKUP:
            return Decimal('0.00')

        if subtotal >= cls.FREE_SHIPPING_THRESHOLD and method == ShippingMethod.STANDARD:
            return Decimal('0.00')

        base_rate = cls.BASE_RATES[method]
        weight_charge = cls.WEIGHT_RATE * Decimal(str(weight_kg))

        # International shipping surcharge
        if destination.country != 'US':
            base_rate *= Decimal('1.5')

        total = base_rate + weight_charge
        return total.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)

    @classmethod
    def get_estimated_delivery(cls, method: ShippingMethod, is_international: bool) -> datetime:
        days = {
            ShippingMethod.STANDARD: 7,
            ShippingMethod.EXPRESS: 3,
            ShippingMethod.OVERNIGHT: 1,
            ShippingMethod.PICKUP: 0
        }

        base_days = days[method]
        if is_international:
            base_days += 5

        return datetime.now() + timedelta(days=base_days)


class CouponValidator:
    def __init__(self):
        self.coupons = {
            'SAVE10': {'type': 'percent', 'value': 10, 'min_purchase': Decimal('50.00')},
            'SAVE20': {'type': 'percent', 'value': 20, 'min_purchase': Decimal('100.00')},
            'FLAT15': {'type': 'fixed', 'value': Decimal('15.00'), 'min_purchase': Decimal('75.00')},
            'FREESHIP': {'type': 'free_shipping', 'value': True, 'min_purchase': Decimal('0.00')},
            'VIP25': {'type': 'percent', 'value': 25, 'min_purchase': Decimal('200.00'), 'vip_only': True}
        }

    def validate_coupon(self, code: str, subtotal: Decimal, is_vip: bool = False) -> Optional[Dict]:
        if code not in self.coupons:
            return None

        coupon = self.coupons[code]

        if subtotal < coupon['min_purchase']:
            return None

        if coupon.get('vip_only') and not is_vip:
            return None

        return coupon

    def apply_coupon(self, code: str, subtotal: Decimal, is_vip: bool = False) -> Decimal:
        coupon = self.validate_coupon(code, subtotal, is_vip)

        if not coupon:
            return Decimal('0.00')

        if coupon['type'] == 'percent':
            discount = subtotal * Decimal(str(coupon['value'] / 100))
        elif coupon['type'] == 'fixed':
            discount = coupon['value']
        else:
            discount = Decimal('0.00')

        return discount.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)


class PaymentProcessor(ABC):
    @abstractmethod
    def process_payment(self, amount: Decimal, payment_details: Dict) -> Dict:
        pass

    @abstractmethod
    def refund_payment(self, transaction_id: str, amount: Decimal) -> Dict:
        pass


class CreditCardProcessor(PaymentProcessor):
    def __init__(self):
        self.transactions = {}

    def validate_card(self, card_number: str) -> bool:
        # Luhn algorithm validation
        digits = [int(d) for d in card_number.replace(' ', '').replace('-', '')]
        odd_digits = digits[-1::-2]
        even_digits = digits[-2::-2]

        checksum = sum(odd_digits)
        for digit in even_digits:
            checksum += sum(divmod(digit * 2, 10))

        return checksum % 10 == 0

    def process_payment(self, amount: Decimal, payment_details: Dict) -> Dict:
        card_number = payment_details.get('card_number', '')

        if not self.validate_card(card_number):
            return {
                'success': False,
                'error': 'Invalid card number',
                'transaction_id': None
            }

        # Simulate payment processing
        transaction_id = hashlib.sha256(
            f"{card_number}{amount}{datetime.now().isoformat()}".encode()
        ).hexdigest()[:16]

        self.transactions[transaction_id] = {
            'amount': amount,
            'status': 'completed',
            'timestamp': datetime.now()
        }

        return {
            'success': True,
            'transaction_id': transaction_id,
            'amount': amount
        }

    def refund_payment(self, transaction_id: str, amount: Decimal) -> Dict:
        if transaction_id not in self.transactions:
            return {'success': False, 'error': 'Transaction not found'}

        original = self.transactions[transaction_id]
        if amount > original['amount']:
            return {'success': False, 'error': 'Refund amount exceeds original'}

        original['status'] = 'refunded'
        original['refund_amount'] = amount

        return {'success': True, 'refund_id': f"REF-{transaction_id}"}


@dataclass
class Order:
    id: str
    customer: Customer
    items: List[CartItem]
    shipping_address: Address
    billing_address: Address
    shipping_method: ShippingMethod
    payment_method: PaymentMethod
    subtotal: Decimal
    tax: Decimal
    shipping_cost: Decimal
    discount: Decimal
    total: Decimal
    status: OrderStatus = OrderStatus.PENDING
    transaction_id: Optional[str] = None
    tracking_number: Optional[str] = None
    notes: str = ""
    created_at: datetime = field(default_factory=datetime.now)
    updated_at: datetime = field(default_factory=datetime.now)

    def calculate_total(self) -> Decimal:
        return self.subtotal + self.tax + self.shipping_cost - self.discount

    def can_cancel(self) -> bool:
        return self.status in [OrderStatus.PENDING, OrderStatus.CONFIRMED]

    def can_refund(self) -> bool:
        return self.status in [OrderStatus.DELIVERED, OrderStatus.SHIPPED]


class OrderManager:
    def __init__(self):
        self.orders: Dict[str, Order] = {}
        self.order_counter = 0
        self.coupon_validator = CouponValidator()
        self.payment_processors = {
            PaymentMethod.CREDIT_CARD: CreditCardProcessor(),
            PaymentMethod.DEBIT_CARD: CreditCardProcessor(),
        }

    def generate_order_id(self) -> str:
        self.order_counter += 1
        timestamp = datetime.now().strftime('%Y%m%d')
        return f"ORD-{timestamp}-{self.order_counter:06d}"

    def create_order(
        self,
        cart: ShoppingCart,
        shipping_address: Address,
        billing_address: Address,
        shipping_method: ShippingMethod,
        payment_method: PaymentMethod,
        payment_details: Dict,
        coupon_codes: List[str] = None
    ) -> Optional[Order]:
        if cart.is_empty():
            logger.error("Cannot create order from empty cart")
            return None

        if not shipping_address.validate():
            logger.error("Invalid shipping address")
            return None

        # Calculate order totals
        subtotal = cart.get_subtotal()
        tax = TaxCalculator.calculate_tax(subtotal, shipping_address)
        shipping_cost = ShippingCalculator.calculate_shipping(
            shipping_method,
            cart.get_total_weight(),
            subtotal,
            shipping_address
        )

        # Apply coupons
        total_discount = Decimal('0.00')
        if coupon_codes:
            is_vip = cart.customer.loyalty_points >= 1000
            for code in coupon_codes:
                discount = self.coupon_validator.apply_coupon(code, subtotal, is_vip)
                total_discount += discount

        # Create order items from cart
        order_items = list(cart.items.values())

        # Reserve stock for all items
        for item in order_items:
            if not item.product.reserve_stock(item.quantity):
                logger.error(f"Failed to reserve stock for product {item.product.id}")
                # Release any already reserved stock
                for reserved_item in order_items:
                    if reserved_item == item:
                        break
                    reserved_item.product.release_stock(reserved_item.quantity)
                return None

        # Calculate final total
        total = subtotal + tax + shipping_cost - total_discount

        # Process payment
        if payment_method in self.payment_processors:
            processor = self.payment_processors[payment_method]
            payment_result = processor.process_payment(total, payment_details)

            if not payment_result['success']:
                logger.error(f"Payment failed: {payment_result.get('error')}")
                # Release reserved stock
                for item in order_items:
                    item.product.release_stock(item.quantity)
                return None

            transaction_id = payment_result['transaction_id']
        else:
            transaction_id = None

        # Create order
        order = Order(
            id=self.generate_order_id(),
            customer=cart.customer,
            items=order_items,
            shipping_address=shipping_address,
            billing_address=billing_address,
            shipping_method=shipping_method,
            payment_method=payment_method,
            subtotal=subtotal,
            tax=tax,
            shipping_cost=shipping_cost,
            discount=total_discount,
            total=total,
            status=OrderStatus.CONFIRMED,
            transaction_id=transaction_id
        )

        self.orders[order.id] = order

        # Award loyalty points
        points_earned = int(total / 10)
        cart.customer.add_loyalty_points(points_earned)

        # Clear cart
        cart.clear()

        logger.info(f"Order {order.id} created successfully")
        return order

    def get_order(self, order_id: str) -> Optional[Order]:
        return self.orders.get(order_id)

    def update_order_status(self, order_id: str, new_status: OrderStatus) -> bool:
        order = self.get_order(order_id)
        if not order:
            return False

        order.status = new_status
        order.updated_at = datetime.now()
        return True

    def cancel_order(self, order_id: str) -> bool:
        order = self.get_order(order_id)
        if not order or not order.can_cancel():
            return False

        # Release stock
        for item in order.items:
            item.product.release_stock(item.quantity)

        # Process refund if payment was made
        if order.transaction_id and order.payment_method in self.payment_processors:
            processor = self.payment_processors[order.payment_method]
            processor.refund_payment(order.transaction_id, order.total)

        order.status = OrderStatus.CANCELLED
        order.updated_at = datetime.now()
        return True

    def get_customer_orders(self, customer_id: str) -> List[Order]:
        return [
            order for order in self.orders.values()
            if order.customer.id == customer_id
        ]

    def generate_order_report(self, start_date: datetime, end_date: datetime) -> Dict:
        orders_in_range = [
            order for order in self.orders.values()
            if start_date <= order.created_at <= end_date
        ]

        total_revenue = sum(order.total for order in orders_in_range)
        total_orders = len(orders_in_range)

        status_breakdown = defaultdict(int)
        for order in orders_in_range:
            status_breakdown[order.status.value] += 1

        return {
            'period': {'start': start_date.isoformat(), 'end': end_date.isoformat()},
            'total_orders': total_orders,
            'total_revenue': str(total_revenue),
            'average_order_value': str(total_revenue / total_orders) if total_orders > 0 else '0',
            'status_breakdown': dict(status_breakdown)
        }


class InventoryManager:
    def __init__(self):
        self.products: Dict[str, Product] = {}
        self.low_stock_threshold = 10

    def add_product(self, product: Product) -> bool:
        if product.id in self.products:
            return False
        self.products[product.id] = product
        return True

    def get_product(self, product_id: str) -> Optional[Product]:
        return self.products.get(product_id)

    def update_stock(self, product_id: str, quantity: int) -> bool:
        product = self.get_product(product_id)
        if not product:
            return False
        product.stock_quantity = quantity
        return True

    def get_low_stock_products(self) -> List[Product]:
        return [
            product for product in self.products.values()
            if product.stock_quantity <= self.low_stock_threshold
        ]

    def search_products(
        self,
        query: str = None,
        category: str = None,
        min_price: Decimal = None,
        max_price: Decimal = None,
        in_stock_only: bool = True
    ) -> List[Product]:
        results = list(self.products.values())

        if in_stock_only:
            results = [p for p in results if p.is_available()]

        if query:
            query_lower = query.lower()
            results = [
                p for p in results
                if query_lower in p.name.lower() or query_lower in p.description.lower()
            ]

        if category:
            results = [p for p in results if p.category == category]

        if min_price is not None:
            results = [p for p in results if p.get_discounted_price() >= min_price]

        if max_price is not None:
            results = [p for p in results if p.get_discounted_price() <= max_price]

        return results


async def main():
    # Initialize managers
    inventory = InventoryManager()
    order_manager = OrderManager()

    # Add sample products
    products = [
        Product(
            id="PROD001",
            name="Wireless Bluetooth Headphones",
            description="Premium noise-cancelling wireless headphones with 30-hour battery life",
            price=Decimal("149.99"),
            stock_quantity=50,
            category="Electronics",
            weight_kg=0.3,
            dimensions={"length": 20, "width": 18, "height": 8},
            discount_percent=10.0,
            tags=["audio", "wireless", "bluetooth"]
        ),
        Product(
            id="PROD002",
            name="Organic Coffee Beans",
            description="Fair trade organic coffee beans from Colombia, 1kg bag",
            price=Decimal("24.99"),
            stock_quantity=100,
            category="Food & Beverage",
            weight_kg=1.0,
            dimensions={"length": 15, "width": 10, "height": 25},
            tags=["coffee", "organic", "fair-trade"]
        ),
        Product(
            id="PROD003",
            name="Running Shoes Pro",
            description="Lightweight professional running shoes with advanced cushioning",
            price=Decimal("199.99"),
            stock_quantity=30,
            category="Sports",
            weight_kg=0.5,
            dimensions={"length": 32, "width": 12, "height": 12},
            discount_percent=15.0,
            tags=["shoes", "running", "sports"]
        )
    ]

    for product in products:
        inventory.add_product(product)

    # Create customer
    customer = Customer(
        id="CUST001",
        email="john.doe@example.com",
        first_name="John",
        last_name="Doe",
        phone="+1-555-123-4567",
        is_verified=True,
        loyalty_points=500
    )

    shipping_address = Address(
        street="123 Main Street",
        city="San Francisco",
        state="CA",
        postal_code="94102",
        country="US"
    )
    customer.shipping_addresses.append(shipping_address)

    # Create shopping cart
    cart = ShoppingCart(customer)
    cart.add_item(products[0], 2)
    cart.add_item(products[1], 3)
    cart.add_item(products[2], 1)

    print(f"Cart subtotal: ${cart.get_subtotal()}")
    print(f"Cart items: {cart.get_item_count()}")
    print(f"Cart weight: {cart.get_total_weight()}kg")

    # Apply coupon
    cart.apply_coupon("SAVE10")

    # Create order
    payment_details = {
        "card_number": "4532015112830366",
        "expiry": "12/25",
        "cvv": "123"
    }

    order = order_manager.create_order(
        cart=cart,
        shipping_address=shipping_address,
        billing_address=shipping_address,
        shipping_method=ShippingMethod.EXPRESS,
        payment_method=PaymentMethod.CREDIT_CARD,
        payment_details=payment_details,
        coupon_codes=["SAVE10"]
    )

    if order:
        print(f"\nOrder created: {order.id}")
        print(f"Subtotal: ${order.subtotal}")
        print(f"Tax: ${order.tax}")
        print(f"Shipping: ${order.shipping_cost}")
        print(f"Discount: ${order.discount}")
        print(f"Total: ${order.total}")
        print(f"Status: {order.status.value}")
        print(f"Customer loyalty points: {customer.loyalty_points}")


if __name__ == "__main__":
    asyncio.run(main())
