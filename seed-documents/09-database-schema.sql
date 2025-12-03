-- Enterprise Resource Planning (ERP) Database Schema
-- Comprehensive database design for manufacturing, inventory, sales, and HR management
-- PostgreSQL 15+ compatible with advanced features

-- ============================================================================
-- EXTENSIONS AND CONFIGURATIONS
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "btree_gin";
CREATE EXTENSION IF NOT EXISTS "tablefunc";

-- Set default timezone
SET timezone = 'UTC';

-- ============================================================================
-- CUSTOM TYPES AND DOMAINS
-- ============================================================================

-- Email domain with validation
CREATE DOMAIN email_address AS VARCHAR(255)
CHECK (VALUE ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');

-- Phone number domain
CREATE DOMAIN phone_number AS VARCHAR(20)
CHECK (VALUE ~* '^\+?[0-9\s\-\(\)]{10,20}$');

-- Positive decimal for monetary values
CREATE DOMAIN positive_money AS DECIMAL(19,4)
CHECK (VALUE >= 0);

-- Percentage domain
CREATE DOMAIN percentage AS DECIMAL(5,2)
CHECK (VALUE >= 0 AND VALUE <= 100);

-- Status enums
CREATE TYPE order_status AS ENUM (
    'draft', 'pending_approval', 'approved', 'in_production',
    'quality_check', 'ready_to_ship', 'shipped', 'delivered',
    'cancelled', 'returned', 'refunded'
);

CREATE TYPE employee_status AS ENUM (
    'active', 'on_leave', 'suspended', 'terminated', 'retired'
);

CREATE TYPE inventory_transaction_type AS ENUM (
    'receipt', 'shipment', 'adjustment_in', 'adjustment_out',
    'transfer_in', 'transfer_out', 'production_consumption',
    'production_output', 'return_to_vendor', 'customer_return',
    'scrap', 'cycle_count'
);

CREATE TYPE payment_method AS ENUM (
    'cash', 'credit_card', 'debit_card', 'bank_transfer',
    'check', 'wire_transfer', 'cryptocurrency', 'credit_terms'
);

CREATE TYPE payment_status AS ENUM (
    'pending', 'processing', 'completed', 'failed',
    'refunded', 'partially_refunded', 'disputed', 'cancelled'
);

-- ============================================================================
-- CORE ORGANIZATION TABLES
-- ============================================================================

-- Company/Organization master
CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    parent_id UUID REFERENCES organizations(id),
    code VARCHAR(20) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    legal_name VARCHAR(255),
    tax_id VARCHAR(50),
    registration_number VARCHAR(50),
    industry_code VARCHAR(10),
    founded_date DATE,
    website VARCHAR(255),
    logo_url VARCHAR(500),
    is_active BOOLEAN DEFAULT TRUE,
    settings JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID,
    updated_by UUID
);

-- Departments within organizations
CREATE TABLE departments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    parent_department_id UUID REFERENCES departments(id),
    code VARCHAR(20) NOT NULL,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    cost_center VARCHAR(20),
    manager_id UUID, -- Will reference employees table
    budget_amount positive_money,
    budget_currency CHAR(3) DEFAULT 'USD',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(organization_id, code)
);

-- Physical locations/facilities
CREATE TABLE locations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    code VARCHAR(20) NOT NULL,
    name VARCHAR(100) NOT NULL,
    location_type VARCHAR(50) NOT NULL, -- warehouse, office, factory, store, etc.
    address_line1 VARCHAR(255) NOT NULL,
    address_line2 VARCHAR(255),
    city VARCHAR(100) NOT NULL,
    state_province VARCHAR(100),
    postal_code VARCHAR(20),
    country_code CHAR(2) NOT NULL,
    latitude DECIMAL(10, 8),
    longitude DECIMAL(11, 8),
    timezone VARCHAR(50) DEFAULT 'UTC',
    phone phone_number,
    email email_address,
    operating_hours JSONB,
    storage_capacity INTEGER,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(organization_id, code)
);

CREATE INDEX idx_locations_geo ON locations USING GIST (
    ll_to_earth(latitude, longitude)
) WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

-- ============================================================================
-- HUMAN RESOURCES TABLES
-- ============================================================================

-- Employee master table
CREATE TABLE employees (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    employee_number VARCHAR(20) NOT NULL,
    department_id UUID REFERENCES departments(id),
    reports_to UUID REFERENCES employees(id),
    primary_location_id UUID REFERENCES locations(id),

    -- Personal information
    first_name VARCHAR(100) NOT NULL,
    middle_name VARCHAR(100),
    last_name VARCHAR(100) NOT NULL,
    preferred_name VARCHAR(100),
    date_of_birth DATE,
    gender VARCHAR(20),
    nationality VARCHAR(50),
    national_id VARCHAR(50),
    passport_number VARCHAR(50),

    -- Contact information
    personal_email email_address,
    work_email email_address NOT NULL,
    personal_phone phone_number,
    work_phone phone_number,
    emergency_contact_name VARCHAR(200),
    emergency_contact_phone phone_number,
    emergency_contact_relationship VARCHAR(50),

    -- Address
    address_line1 VARCHAR(255),
    address_line2 VARCHAR(255),
    city VARCHAR(100),
    state_province VARCHAR(100),
    postal_code VARCHAR(20),
    country_code CHAR(2),

    -- Employment details
    hire_date DATE NOT NULL,
    termination_date DATE,
    job_title VARCHAR(100) NOT NULL,
    job_level VARCHAR(20),
    employment_type VARCHAR(50) DEFAULT 'full_time', -- full_time, part_time, contractor, intern
    status employee_status DEFAULT 'active',

    -- Compensation
    base_salary positive_money,
    salary_currency CHAR(3) DEFAULT 'USD',
    pay_frequency VARCHAR(20) DEFAULT 'monthly', -- weekly, bi_weekly, monthly, annually

    -- System fields
    photo_url VARCHAR(500),
    is_active BOOLEAN DEFAULT TRUE,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    UNIQUE(organization_id, employee_number),
    UNIQUE(work_email)
);

CREATE INDEX idx_employees_department ON employees(department_id) WHERE is_active = TRUE;
CREATE INDEX idx_employees_manager ON employees(reports_to) WHERE is_active = TRUE;
CREATE INDEX idx_employees_name ON employees USING GIN (
    (first_name || ' ' || last_name) gin_trgm_ops
);

-- Add foreign key for department manager after employees table exists
ALTER TABLE departments ADD CONSTRAINT fk_department_manager
    FOREIGN KEY (manager_id) REFERENCES employees(id);

-- Employee positions history
CREATE TABLE employee_positions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    employee_id UUID NOT NULL REFERENCES employees(id),
    department_id UUID NOT NULL REFERENCES departments(id),
    job_title VARCHAR(100) NOT NULL,
    job_level VARCHAR(20),
    reports_to UUID REFERENCES employees(id),
    location_id UUID REFERENCES locations(id),
    start_date DATE NOT NULL,
    end_date DATE,
    reason_for_change VARCHAR(255),
    base_salary positive_money,
    salary_currency CHAR(3) DEFAULT 'USD',
    is_current BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id)
);

CREATE INDEX idx_employee_positions_current ON employee_positions(employee_id)
    WHERE is_current = TRUE;

-- Time off / Leave management
CREATE TABLE leave_types (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    code VARCHAR(20) NOT NULL,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    is_paid BOOLEAN DEFAULT TRUE,
    accrual_rate DECIMAL(5,2), -- days per month
    max_carryover INTEGER,
    max_balance INTEGER,
    requires_approval BOOLEAN DEFAULT TRUE,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(organization_id, code)
);

CREATE TABLE leave_balances (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    employee_id UUID NOT NULL REFERENCES employees(id),
    leave_type_id UUID NOT NULL REFERENCES leave_types(id),
    year INTEGER NOT NULL,
    opening_balance DECIMAL(5,2) DEFAULT 0,
    accrued DECIMAL(5,2) DEFAULT 0,
    used DECIMAL(5,2) DEFAULT 0,
    adjustment DECIMAL(5,2) DEFAULT 0,
    current_balance DECIMAL(5,2) GENERATED ALWAYS AS
        (opening_balance + accrued - used + adjustment) STORED,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(employee_id, leave_type_id, year)
);

CREATE TABLE leave_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    employee_id UUID NOT NULL REFERENCES employees(id),
    leave_type_id UUID NOT NULL REFERENCES leave_types(id),
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    total_days DECIMAL(5,2) NOT NULL,
    reason TEXT,
    status VARCHAR(20) DEFAULT 'pending', -- pending, approved, rejected, cancelled
    approved_by UUID REFERENCES employees(id),
    approved_at TIMESTAMPTZ,
    rejection_reason TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT valid_date_range CHECK (end_date >= start_date)
);

CREATE INDEX idx_leave_requests_employee ON leave_requests(employee_id, status);
CREATE INDEX idx_leave_requests_dates ON leave_requests(start_date, end_date);

-- ============================================================================
-- PRODUCT AND INVENTORY TABLES
-- ============================================================================

-- Product categories (hierarchical)
CREATE TABLE product_categories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    parent_id UUID REFERENCES product_categories(id),
    code VARCHAR(20) NOT NULL,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    image_url VARCHAR(500),
    sort_order INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(organization_id, code)
);

-- Units of measure
CREATE TABLE units_of_measure (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    code VARCHAR(10) NOT NULL,
    name VARCHAR(50) NOT NULL,
    category VARCHAR(50), -- weight, length, volume, quantity, time
    base_unit_id UUID REFERENCES units_of_measure(id),
    conversion_factor DECIMAL(18,8) DEFAULT 1,
    is_active BOOLEAN DEFAULT TRUE,
    UNIQUE(organization_id, code)
);

-- Products master table
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    category_id UUID REFERENCES product_categories(id),

    -- Identification
    sku VARCHAR(50) NOT NULL,
    upc VARCHAR(20),
    ean VARCHAR(20),
    manufacturer_part_number VARCHAR(50),

    -- Basic information
    name VARCHAR(255) NOT NULL,
    short_description VARCHAR(500),
    full_description TEXT,

    -- Classification
    product_type VARCHAR(50) DEFAULT 'physical', -- physical, digital, service, bundle
    is_serialized BOOLEAN DEFAULT FALSE,
    is_lot_tracked BOOLEAN DEFAULT FALSE,
    is_perishable BOOLEAN DEFAULT FALSE,
    shelf_life_days INTEGER,

    -- Units and dimensions
    base_uom_id UUID NOT NULL REFERENCES units_of_measure(id),
    weight DECIMAL(10,4),
    weight_uom_id UUID REFERENCES units_of_measure(id),
    length DECIMAL(10,4),
    width DECIMAL(10,4),
    height DECIMAL(10,4),
    dimension_uom_id UUID REFERENCES units_of_measure(id),

    -- Pricing
    standard_cost positive_money,
    list_price positive_money,
    min_price positive_money,
    currency_code CHAR(3) DEFAULT 'USD',

    -- Inventory settings
    reorder_point INTEGER DEFAULT 0,
    reorder_quantity INTEGER DEFAULT 0,
    safety_stock INTEGER DEFAULT 0,
    max_stock INTEGER,
    lead_time_days INTEGER DEFAULT 0,

    -- Tax and compliance
    tax_category VARCHAR(50),
    hs_code VARCHAR(20), -- Harmonized System code for customs
    country_of_origin CHAR(2),

    -- Media
    primary_image_url VARCHAR(500),
    images JSONB DEFAULT '[]',
    documents JSONB DEFAULT '[]',

    -- Status and metadata
    status VARCHAR(20) DEFAULT 'active', -- active, discontinued, pending, draft
    is_sellable BOOLEAN DEFAULT TRUE,
    is_purchasable BOOLEAN DEFAULT TRUE,
    launch_date DATE,
    discontinue_date DATE,
    attributes JSONB DEFAULT '{}',
    tags TEXT[],

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id),
    updated_by UUID REFERENCES employees(id),

    UNIQUE(organization_id, sku)
);

CREATE INDEX idx_products_category ON products(category_id) WHERE status = 'active';
CREATE INDEX idx_products_sku ON products(sku);
CREATE INDEX idx_products_upc ON products(upc) WHERE upc IS NOT NULL;
CREATE INDEX idx_products_name ON products USING GIN (name gin_trgm_ops);
CREATE INDEX idx_products_tags ON products USING GIN (tags);
CREATE INDEX idx_products_attributes ON products USING GIN (attributes);

-- Product variants (for products with options like size, color)
CREATE TABLE product_variants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    sku VARCHAR(50) NOT NULL,
    name VARCHAR(255) NOT NULL,
    option_values JSONB NOT NULL, -- {"color": "red", "size": "large"}
    additional_cost positive_money DEFAULT 0,
    additional_price positive_money DEFAULT 0,
    weight_adjustment DECIMAL(10,4) DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(product_id, sku)
);

-- Bill of Materials (BOM) for manufactured products
CREATE TABLE bills_of_material (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    parent_product_id UUID NOT NULL REFERENCES products(id),
    version INTEGER NOT NULL DEFAULT 1,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    effective_date DATE NOT NULL,
    expiration_date DATE,
    status VARCHAR(20) DEFAULT 'active', -- draft, active, obsolete
    standard_batch_size DECIMAL(18,4) DEFAULT 1,
    standard_batch_uom_id UUID REFERENCES units_of_measure(id),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id),
    UNIQUE(parent_product_id, version)
);

CREATE TABLE bom_components (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bom_id UUID NOT NULL REFERENCES bills_of_material(id) ON DELETE CASCADE,
    component_product_id UUID NOT NULL REFERENCES products(id),
    quantity DECIMAL(18,6) NOT NULL,
    uom_id UUID NOT NULL REFERENCES units_of_measure(id),
    scrap_percentage percentage DEFAULT 0,
    is_critical BOOLEAN DEFAULT FALSE,
    lead_time_offset_days INTEGER DEFAULT 0,
    notes TEXT,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_bom_components_bom ON bom_components(bom_id);
CREATE INDEX idx_bom_components_product ON bom_components(component_product_id);

-- Inventory locations within warehouses
CREATE TABLE inventory_zones (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    location_id UUID NOT NULL REFERENCES locations(id),
    code VARCHAR(20) NOT NULL,
    name VARCHAR(100) NOT NULL,
    zone_type VARCHAR(50), -- receiving, storage, picking, packing, shipping, quarantine
    temperature_controlled BOOLEAN DEFAULT FALSE,
    min_temperature DECIMAL(5,2),
    max_temperature DECIMAL(5,2),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(location_id, code)
);

CREATE TABLE inventory_bins (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    zone_id UUID NOT NULL REFERENCES inventory_zones(id),
    code VARCHAR(30) NOT NULL,
    aisle VARCHAR(10),
    rack VARCHAR(10),
    shelf VARCHAR(10),
    bin VARCHAR(10),
    max_weight DECIMAL(10,2),
    max_volume DECIMAL(10,2),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(zone_id, code)
);

-- Current inventory levels
CREATE TABLE inventory (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    product_id UUID NOT NULL REFERENCES products(id),
    variant_id UUID REFERENCES product_variants(id),
    location_id UUID NOT NULL REFERENCES locations(id),
    bin_id UUID REFERENCES inventory_bins(id),

    -- Lot/Serial tracking
    lot_number VARCHAR(50),
    serial_number VARCHAR(50),
    expiration_date DATE,
    manufacture_date DATE,

    -- Quantities
    quantity_on_hand DECIMAL(18,4) NOT NULL DEFAULT 0,
    quantity_reserved DECIMAL(18,4) NOT NULL DEFAULT 0,
    quantity_available DECIMAL(18,4) GENERATED ALWAYS AS
        (quantity_on_hand - quantity_reserved) STORED,
    quantity_in_transit DECIMAL(18,4) DEFAULT 0,

    -- Cost tracking
    unit_cost positive_money,
    total_cost positive_money GENERATED ALWAYS AS
        (quantity_on_hand * COALESCE(unit_cost, 0)) STORED,

    -- Status
    status VARCHAR(20) DEFAULT 'available', -- available, quarantine, damaged, expired
    last_count_date DATE,
    last_movement_date TIMESTAMPTZ,

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    UNIQUE NULLS NOT DISTINCT (product_id, variant_id, location_id, bin_id, lot_number, serial_number)
);

CREATE INDEX idx_inventory_product ON inventory(product_id, location_id);
CREATE INDEX idx_inventory_location ON inventory(location_id);
CREATE INDEX idx_inventory_available ON inventory(product_id)
    WHERE quantity_available > 0 AND status = 'available';

-- Inventory transactions log
CREATE TABLE inventory_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    transaction_type inventory_transaction_type NOT NULL,
    transaction_date TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reference_type VARCHAR(50), -- purchase_order, sales_order, transfer, adjustment
    reference_id UUID,
    reference_number VARCHAR(50),

    product_id UUID NOT NULL REFERENCES products(id),
    variant_id UUID REFERENCES product_variants(id),
    from_location_id UUID REFERENCES locations(id),
    to_location_id UUID REFERENCES locations(id),
    from_bin_id UUID REFERENCES inventory_bins(id),
    to_bin_id UUID REFERENCES inventory_bins(id),

    lot_number VARCHAR(50),
    serial_number VARCHAR(50),

    quantity DECIMAL(18,4) NOT NULL,
    uom_id UUID NOT NULL REFERENCES units_of_measure(id),
    unit_cost positive_money,
    total_cost positive_money,

    reason_code VARCHAR(20),
    notes TEXT,

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id)
);

CREATE INDEX idx_inv_trans_product ON inventory_transactions(product_id, transaction_date);
CREATE INDEX idx_inv_trans_date ON inventory_transactions(transaction_date);
CREATE INDEX idx_inv_trans_reference ON inventory_transactions(reference_type, reference_id);

-- ============================================================================
-- CUSTOMER AND VENDOR TABLES
-- ============================================================================

-- Customer master
CREATE TABLE customers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    customer_number VARCHAR(20) NOT NULL,

    -- Customer type
    customer_type VARCHAR(20) DEFAULT 'business', -- business, individual

    -- Business customers
    company_name VARCHAR(255),
    tax_id VARCHAR(50),
    industry VARCHAR(100),
    website VARCHAR(255),

    -- Individual customers
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    date_of_birth DATE,

    -- Contact
    primary_email email_address,
    secondary_email email_address,
    phone phone_number,
    mobile phone_number,
    fax VARCHAR(20),

    -- Classification
    customer_group VARCHAR(50),
    price_level VARCHAR(20),
    credit_limit positive_money,
    payment_terms INTEGER DEFAULT 30, -- days
    default_payment_method payment_method,
    tax_exempt BOOLEAN DEFAULT FALSE,
    tax_exempt_number VARCHAR(50),

    -- Account status
    status VARCHAR(20) DEFAULT 'active', -- prospect, active, inactive, blocked
    account_opened_date DATE DEFAULT CURRENT_DATE,
    last_order_date DATE,
    total_orders INTEGER DEFAULT 0,
    total_revenue positive_money DEFAULT 0,

    -- Sales assignment
    sales_rep_id UUID REFERENCES employees(id),
    territory VARCHAR(50),

    -- Notes and metadata
    notes TEXT,
    tags TEXT[],
    custom_fields JSONB DEFAULT '{}',

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id),

    UNIQUE(organization_id, customer_number)
);

CREATE INDEX idx_customers_name ON customers USING GIN (
    COALESCE(company_name, first_name || ' ' || last_name) gin_trgm_ops
);
CREATE INDEX idx_customers_email ON customers(primary_email);
CREATE INDEX idx_customers_sales_rep ON customers(sales_rep_id) WHERE status = 'active';

-- Customer addresses
CREATE TABLE customer_addresses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    address_type VARCHAR(20) NOT NULL, -- billing, shipping, both
    is_default BOOLEAN DEFAULT FALSE,
    attention_to VARCHAR(100),
    address_line1 VARCHAR(255) NOT NULL,
    address_line2 VARCHAR(255),
    city VARCHAR(100) NOT NULL,
    state_province VARCHAR(100),
    postal_code VARCHAR(20),
    country_code CHAR(2) NOT NULL,
    phone phone_number,
    delivery_instructions TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_customer_addresses ON customer_addresses(customer_id, address_type);

-- Vendors/Suppliers master
CREATE TABLE vendors (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    vendor_number VARCHAR(20) NOT NULL,

    -- Company information
    company_name VARCHAR(255) NOT NULL,
    legal_name VARCHAR(255),
    tax_id VARCHAR(50),
    duns_number VARCHAR(15),

    -- Contact
    primary_contact_name VARCHAR(200),
    primary_contact_title VARCHAR(100),
    email email_address,
    phone phone_number,
    fax VARCHAR(20),
    website VARCHAR(255),

    -- Address
    address_line1 VARCHAR(255),
    address_line2 VARCHAR(255),
    city VARCHAR(100),
    state_province VARCHAR(100),
    postal_code VARCHAR(20),
    country_code CHAR(2),

    -- Terms
    payment_terms INTEGER DEFAULT 30,
    default_payment_method payment_method,
    currency_code CHAR(3) DEFAULT 'USD',
    minimum_order_amount positive_money,
    lead_time_days INTEGER DEFAULT 14,

    -- Banking
    bank_name VARCHAR(100),
    bank_account_number VARCHAR(50),
    bank_routing_number VARCHAR(20),
    bank_swift_code VARCHAR(15),

    -- Classification
    vendor_type VARCHAR(50), -- manufacturer, distributor, wholesaler, service
    vendor_category VARCHAR(50),
    is_approved BOOLEAN DEFAULT FALSE,
    approval_date DATE,
    rating DECIMAL(3,2), -- 0.00 to 5.00

    -- Status
    status VARCHAR(20) DEFAULT 'active', -- pending, active, inactive, blocked
    notes TEXT,
    custom_fields JSONB DEFAULT '{}',

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    UNIQUE(organization_id, vendor_number)
);

-- Vendor products (products supplied by vendor)
CREATE TABLE vendor_products (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    vendor_id UUID NOT NULL REFERENCES vendors(id),
    product_id UUID NOT NULL REFERENCES products(id),
    vendor_sku VARCHAR(50),
    vendor_product_name VARCHAR(255),
    unit_cost positive_money NOT NULL,
    currency_code CHAR(3) DEFAULT 'USD',
    minimum_order_quantity DECIMAL(18,4) DEFAULT 1,
    order_multiple DECIMAL(18,4) DEFAULT 1,
    lead_time_days INTEGER,
    is_preferred BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN DEFAULT TRUE,
    effective_date DATE DEFAULT CURRENT_DATE,
    expiration_date DATE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(vendor_id, product_id, effective_date)
);

CREATE INDEX idx_vendor_products_product ON vendor_products(product_id) WHERE is_active = TRUE;

-- ============================================================================
-- SALES ORDER TABLES
-- ============================================================================

-- Sales orders header
CREATE TABLE sales_orders (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    order_number VARCHAR(30) NOT NULL,

    -- Customer
    customer_id UUID NOT NULL REFERENCES customers(id),
    billing_address_id UUID REFERENCES customer_addresses(id),
    shipping_address_id UUID REFERENCES customer_addresses(id),

    -- Dates
    order_date DATE NOT NULL DEFAULT CURRENT_DATE,
    requested_date DATE,
    promised_date DATE,
    shipped_date DATE,
    delivered_date DATE,

    -- Status
    status order_status DEFAULT 'draft',
    priority VARCHAR(20) DEFAULT 'normal', -- low, normal, high, urgent

    -- Pricing
    currency_code CHAR(3) DEFAULT 'USD',
    subtotal positive_money DEFAULT 0,
    discount_amount positive_money DEFAULT 0,
    discount_percent percentage DEFAULT 0,
    tax_amount positive_money DEFAULT 0,
    shipping_amount positive_money DEFAULT 0,
    total_amount positive_money DEFAULT 0,

    -- Payment
    payment_terms INTEGER,
    payment_method payment_method,
    payment_status payment_status DEFAULT 'pending',

    -- Shipping
    shipping_method VARCHAR(50),
    carrier VARCHAR(50),
    tracking_number VARCHAR(100),
    shipping_weight DECIMAL(10,4),

    -- Sales info
    sales_rep_id UUID REFERENCES employees(id),
    source VARCHAR(50), -- web, phone, email, in_person, marketplace
    campaign_id UUID,

    -- Notes
    internal_notes TEXT,
    customer_notes TEXT,

    -- Approval workflow
    requires_approval BOOLEAN DEFAULT FALSE,
    approved_by UUID REFERENCES employees(id),
    approved_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id),
    updated_by UUID REFERENCES employees(id),

    UNIQUE(organization_id, order_number)
);

CREATE INDEX idx_sales_orders_customer ON sales_orders(customer_id);
CREATE INDEX idx_sales_orders_status ON sales_orders(status, order_date);
CREATE INDEX idx_sales_orders_date ON sales_orders(order_date);

-- Sales order line items
CREATE TABLE sales_order_lines (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id UUID NOT NULL REFERENCES sales_orders(id) ON DELETE CASCADE,
    line_number INTEGER NOT NULL,

    product_id UUID NOT NULL REFERENCES products(id),
    variant_id UUID REFERENCES product_variants(id),
    description VARCHAR(500),

    quantity_ordered DECIMAL(18,4) NOT NULL,
    quantity_shipped DECIMAL(18,4) DEFAULT 0,
    quantity_backordered DECIMAL(18,4) DEFAULT 0,
    uom_id UUID NOT NULL REFERENCES units_of_measure(id),

    unit_price positive_money NOT NULL,
    discount_percent percentage DEFAULT 0,
    discount_amount positive_money DEFAULT 0,
    tax_rate percentage DEFAULT 0,
    tax_amount positive_money DEFAULT 0,
    line_total positive_money NOT NULL,

    -- Fulfillment
    warehouse_id UUID REFERENCES locations(id),
    requested_date DATE,
    promised_date DATE,

    status VARCHAR(20) DEFAULT 'pending', -- pending, allocated, picked, packed, shipped, delivered

    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    UNIQUE(order_id, line_number)
);

CREATE INDEX idx_so_lines_product ON sales_order_lines(product_id);
CREATE INDEX idx_so_lines_status ON sales_order_lines(status);

-- ============================================================================
-- PURCHASE ORDER TABLES
-- ============================================================================

-- Purchase orders header
CREATE TABLE purchase_orders (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    po_number VARCHAR(30) NOT NULL,

    -- Vendor
    vendor_id UUID NOT NULL REFERENCES vendors(id),

    -- Dates
    order_date DATE NOT NULL DEFAULT CURRENT_DATE,
    expected_date DATE,
    received_date DATE,

    -- Status
    status VARCHAR(20) DEFAULT 'draft', -- draft, pending_approval, approved, sent, partially_received, received, cancelled

    -- Destination
    ship_to_location_id UUID NOT NULL REFERENCES locations(id),

    -- Pricing
    currency_code CHAR(3) DEFAULT 'USD',
    subtotal positive_money DEFAULT 0,
    tax_amount positive_money DEFAULT 0,
    shipping_amount positive_money DEFAULT 0,
    other_charges positive_money DEFAULT 0,
    total_amount positive_money DEFAULT 0,

    -- Payment
    payment_terms INTEGER,

    -- Shipping
    shipping_method VARCHAR(50),
    incoterms VARCHAR(10),

    -- Reference
    vendor_reference VARCHAR(50),
    requisition_id UUID,

    -- Notes
    internal_notes TEXT,
    vendor_notes TEXT,
    terms_conditions TEXT,

    -- Approval
    approved_by UUID REFERENCES employees(id),
    approved_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id),

    UNIQUE(organization_id, po_number)
);

CREATE INDEX idx_purchase_orders_vendor ON purchase_orders(vendor_id);
CREATE INDEX idx_purchase_orders_status ON purchase_orders(status);

-- Purchase order line items
CREATE TABLE purchase_order_lines (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    po_id UUID NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
    line_number INTEGER NOT NULL,

    product_id UUID NOT NULL REFERENCES products(id),
    variant_id UUID REFERENCES product_variants(id),
    vendor_product_id UUID REFERENCES vendor_products(id),
    description VARCHAR(500),

    quantity_ordered DECIMAL(18,4) NOT NULL,
    quantity_received DECIMAL(18,4) DEFAULT 0,
    quantity_rejected DECIMAL(18,4) DEFAULT 0,
    uom_id UUID NOT NULL REFERENCES units_of_measure(id),

    unit_cost positive_money NOT NULL,
    tax_rate percentage DEFAULT 0,
    tax_amount positive_money DEFAULT 0,
    line_total positive_money NOT NULL,

    expected_date DATE,

    status VARCHAR(20) DEFAULT 'pending', -- pending, partially_received, received, cancelled

    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    UNIQUE(po_id, line_number)
);

-- ============================================================================
-- FINANCIAL TABLES
-- ============================================================================

-- Chart of accounts
CREATE TABLE chart_of_accounts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    account_number VARCHAR(20) NOT NULL,
    parent_id UUID REFERENCES chart_of_accounts(id),

    name VARCHAR(100) NOT NULL,
    description TEXT,

    account_type VARCHAR(20) NOT NULL, -- asset, liability, equity, revenue, expense
    account_subtype VARCHAR(50),
    normal_balance VARCHAR(10) NOT NULL, -- debit, credit

    currency_code CHAR(3) DEFAULT 'USD',
    is_header BOOLEAN DEFAULT FALSE,
    is_posting BOOLEAN DEFAULT TRUE,

    -- Control flags
    is_bank_account BOOLEAN DEFAULT FALSE,
    bank_account_number VARCHAR(50),
    is_control_account BOOLEAN DEFAULT FALSE,

    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    UNIQUE(organization_id, account_number)
);

-- General ledger journal entries
CREATE TABLE journal_entries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    entry_number VARCHAR(30) NOT NULL,

    entry_date DATE NOT NULL,
    posting_date DATE NOT NULL,
    period_id UUID, -- References accounting period

    description VARCHAR(500) NOT NULL,
    reference VARCHAR(100),
    source_type VARCHAR(50), -- manual, sales_invoice, purchase_invoice, payment, receipt
    source_id UUID,

    currency_code CHAR(3) DEFAULT 'USD',
    exchange_rate DECIMAL(18,8) DEFAULT 1,

    total_debit positive_money NOT NULL,
    total_credit positive_money NOT NULL,

    status VARCHAR(20) DEFAULT 'draft', -- draft, posted, reversed
    is_adjusting BOOLEAN DEFAULT FALSE,
    is_closing BOOLEAN DEFAULT FALSE,

    reversed_by UUID REFERENCES journal_entries(id),
    reversal_of UUID REFERENCES journal_entries(id),

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    posted_at TIMESTAMPTZ,
    created_by UUID REFERENCES employees(id),
    posted_by UUID REFERENCES employees(id),

    UNIQUE(organization_id, entry_number),
    CONSTRAINT balanced_entry CHECK (total_debit = total_credit)
);

-- Journal entry lines
CREATE TABLE journal_entry_lines (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    entry_id UUID NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
    line_number INTEGER NOT NULL,

    account_id UUID NOT NULL REFERENCES chart_of_accounts(id),

    description VARCHAR(255),
    debit_amount positive_money DEFAULT 0,
    credit_amount positive_money DEFAULT 0,

    -- Dimensional analysis
    department_id UUID REFERENCES departments(id),
    location_id UUID REFERENCES locations(id),
    project_id UUID,
    customer_id UUID REFERENCES customers(id),
    vendor_id UUID REFERENCES vendors(id),
    product_id UUID REFERENCES products(id),

    -- Tax tracking
    tax_code VARCHAR(20),
    tax_amount positive_money DEFAULT 0,

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    UNIQUE(entry_id, line_number),
    CONSTRAINT valid_amounts CHECK (
        (debit_amount > 0 AND credit_amount = 0) OR
        (credit_amount > 0 AND debit_amount = 0)
    )
);

CREATE INDEX idx_jel_account ON journal_entry_lines(account_id);
CREATE INDEX idx_jel_department ON journal_entry_lines(department_id) WHERE department_id IS NOT NULL;

-- Invoices (Accounts Receivable)
CREATE TABLE invoices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    invoice_number VARCHAR(30) NOT NULL,

    customer_id UUID NOT NULL REFERENCES customers(id),
    sales_order_id UUID REFERENCES sales_orders(id),
    billing_address_id UUID REFERENCES customer_addresses(id),

    invoice_date DATE NOT NULL DEFAULT CURRENT_DATE,
    due_date DATE NOT NULL,

    currency_code CHAR(3) DEFAULT 'USD',
    subtotal positive_money DEFAULT 0,
    discount_amount positive_money DEFAULT 0,
    tax_amount positive_money DEFAULT 0,
    total_amount positive_money NOT NULL,
    amount_paid positive_money DEFAULT 0,
    balance_due positive_money GENERATED ALWAYS AS (total_amount - amount_paid) STORED,

    status VARCHAR(20) DEFAULT 'draft', -- draft, sent, viewed, partially_paid, paid, overdue, void

    payment_terms INTEGER,
    notes TEXT,
    terms_conditions TEXT,

    journal_entry_id UUID REFERENCES journal_entries(id),

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id),

    UNIQUE(organization_id, invoice_number)
);

CREATE INDEX idx_invoices_customer ON invoices(customer_id);
CREATE INDEX idx_invoices_status ON invoices(status, due_date);

-- Payments received
CREATE TABLE payments_received (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id),
    payment_number VARCHAR(30) NOT NULL,

    customer_id UUID NOT NULL REFERENCES customers(id),

    payment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    payment_method payment_method NOT NULL,

    currency_code CHAR(3) DEFAULT 'USD',
    amount positive_money NOT NULL,

    -- Payment details
    reference_number VARCHAR(100),
    bank_account_id UUID REFERENCES chart_of_accounts(id),

    -- Card details (tokenized/masked)
    card_last_four VARCHAR(4),
    card_type VARCHAR(20),
    authorization_code VARCHAR(50),

    status payment_status DEFAULT 'completed',

    notes TEXT,
    journal_entry_id UUID REFERENCES journal_entries(id),

    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id),

    UNIQUE(organization_id, payment_number)
);

-- Payment allocations to invoices
CREATE TABLE payment_allocations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    payment_id UUID NOT NULL REFERENCES payments_received(id),
    invoice_id UUID NOT NULL REFERENCES invoices(id),
    amount positive_money NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- AUDIT AND SYSTEM TABLES
-- ============================================================================

-- Audit log for all significant changes
CREATE TABLE audit_log (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    user_id UUID REFERENCES employees(id),
    user_email VARCHAR(255),
    ip_address INET,
    user_agent TEXT,

    action VARCHAR(20) NOT NULL, -- INSERT, UPDATE, DELETE, SELECT
    table_name VARCHAR(100) NOT NULL,
    record_id UUID,

    old_values JSONB,
    new_values JSONB,
    changed_fields TEXT[],

    request_id UUID,
    session_id VARCHAR(100)
);

CREATE INDEX idx_audit_log_timestamp ON audit_log(timestamp);
CREATE INDEX idx_audit_log_table ON audit_log(table_name, record_id);
CREATE INDEX idx_audit_log_user ON audit_log(user_id);

-- System configuration
CREATE TABLE system_config (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id),
    config_key VARCHAR(100) NOT NULL,
    config_value JSONB NOT NULL,
    description TEXT,
    is_sensitive BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(organization_id, config_key)
);

-- Background jobs queue
CREATE TABLE job_queue (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_type VARCHAR(100) NOT NULL,
    payload JSONB NOT NULL,
    priority INTEGER DEFAULT 0,
    status VARCHAR(20) DEFAULT 'pending', -- pending, processing, completed, failed, cancelled
    attempts INTEGER DEFAULT 0,
    max_attempts INTEGER DEFAULT 3,
    scheduled_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    error_message TEXT,
    result JSONB,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES employees(id)
);

CREATE INDEX idx_job_queue_status ON job_queue(status, scheduled_at) WHERE status = 'pending';

-- ============================================================================
-- FUNCTIONS AND TRIGGERS
-- ============================================================================

-- Update timestamp trigger function
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply update trigger to all relevant tables
DO $$
DECLARE
    t TEXT;
BEGIN
    FOR t IN
        SELECT table_name
        FROM information_schema.columns
        WHERE column_name = 'updated_at'
        AND table_schema = 'public'
    LOOP
        EXECUTE format('
            DROP TRIGGER IF EXISTS trigger_update_timestamp ON %I;
            CREATE TRIGGER trigger_update_timestamp
            BEFORE UPDATE ON %I
            FOR EACH ROW
            EXECUTE FUNCTION update_updated_at();
        ', t, t);
    END LOOP;
END;
$$;

-- Function to calculate sales order totals
CREATE OR REPLACE FUNCTION calculate_sales_order_totals()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE sales_orders
    SET
        subtotal = (
            SELECT COALESCE(SUM(line_total), 0)
            FROM sales_order_lines
            WHERE order_id = COALESCE(NEW.order_id, OLD.order_id)
        ),
        tax_amount = (
            SELECT COALESCE(SUM(tax_amount), 0)
            FROM sales_order_lines
            WHERE order_id = COALESCE(NEW.order_id, OLD.order_id)
        ),
        total_amount = (
            SELECT COALESCE(SUM(line_total + tax_amount), 0)
            FROM sales_order_lines
            WHERE order_id = COALESCE(NEW.order_id, OLD.order_id)
        ) + COALESCE(shipping_amount, 0) - COALESCE(discount_amount, 0)
    WHERE id = COALESCE(NEW.order_id, OLD.order_id);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_so_line_totals
AFTER INSERT OR UPDATE OR DELETE ON sales_order_lines
FOR EACH ROW
EXECUTE FUNCTION calculate_sales_order_totals();

-- Function to update inventory on transaction
CREATE OR REPLACE FUNCTION process_inventory_transaction()
RETURNS TRIGGER AS $$
BEGIN
    -- Handle different transaction types
    CASE NEW.transaction_type
        WHEN 'receipt', 'adjustment_in', 'transfer_in', 'production_output', 'customer_return' THEN
            INSERT INTO inventory (
                organization_id, product_id, variant_id, location_id, bin_id,
                lot_number, serial_number, quantity_on_hand, unit_cost
            )
            VALUES (
                NEW.organization_id, NEW.product_id, NEW.variant_id,
                NEW.to_location_id, NEW.to_bin_id,
                NEW.lot_number, NEW.serial_number, NEW.quantity, NEW.unit_cost
            )
            ON CONFLICT (product_id, variant_id, location_id, bin_id, lot_number, serial_number)
            DO UPDATE SET
                quantity_on_hand = inventory.quantity_on_hand + EXCLUDED.quantity_on_hand,
                last_movement_date = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP;

        WHEN 'shipment', 'adjustment_out', 'transfer_out', 'production_consumption', 'return_to_vendor', 'scrap' THEN
            UPDATE inventory
            SET
                quantity_on_hand = quantity_on_hand - NEW.quantity,
                last_movement_date = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP
            WHERE product_id = NEW.product_id
                AND COALESCE(variant_id, uuid_nil()) = COALESCE(NEW.variant_id, uuid_nil())
                AND location_id = NEW.from_location_id
                AND COALESCE(bin_id, uuid_nil()) = COALESCE(NEW.from_bin_id, uuid_nil())
                AND COALESCE(lot_number, '') = COALESCE(NEW.lot_number, '')
                AND COALESCE(serial_number, '') = COALESCE(NEW.serial_number, '');
    END CASE;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_inventory_transaction
AFTER INSERT ON inventory_transactions
FOR EACH ROW
EXECUTE FUNCTION process_inventory_transaction();

-- ============================================================================
-- VIEWS
-- ============================================================================

-- Customer summary view
CREATE OR REPLACE VIEW vw_customer_summary AS
SELECT
    c.id,
    c.customer_number,
    COALESCE(c.company_name, c.first_name || ' ' || c.last_name) AS customer_name,
    c.customer_type,
    c.status,
    c.credit_limit,
    COUNT(DISTINCT so.id) AS total_orders,
    SUM(so.total_amount) AS lifetime_value,
    MAX(so.order_date) AS last_order_date,
    AVG(so.total_amount) AS average_order_value,
    e.first_name || ' ' || e.last_name AS sales_rep_name
FROM customers c
LEFT JOIN sales_orders so ON c.id = so.customer_id AND so.status NOT IN ('draft', 'cancelled')
LEFT JOIN employees e ON c.sales_rep_id = e.id
GROUP BY c.id, e.first_name, e.last_name;

-- Inventory summary view
CREATE OR REPLACE VIEW vw_inventory_summary AS
SELECT
    p.id AS product_id,
    p.sku,
    p.name AS product_name,
    l.id AS location_id,
    l.name AS location_name,
    SUM(i.quantity_on_hand) AS total_on_hand,
    SUM(i.quantity_reserved) AS total_reserved,
    SUM(i.quantity_available) AS total_available,
    SUM(i.total_cost) AS total_value,
    p.reorder_point,
    CASE WHEN SUM(i.quantity_available) <= p.reorder_point THEN TRUE ELSE FALSE END AS needs_reorder
FROM products p
CROSS JOIN locations l
LEFT JOIN inventory i ON p.id = i.product_id AND l.id = i.location_id
WHERE p.status = 'active' AND l.is_active = TRUE
GROUP BY p.id, p.sku, p.name, l.id, l.name, p.reorder_point;

-- Open orders view
CREATE OR REPLACE VIEW vw_open_orders AS
SELECT
    so.id,
    so.order_number,
    so.order_date,
    so.promised_date,
    COALESCE(c.company_name, c.first_name || ' ' || c.last_name) AS customer_name,
    so.status,
    so.total_amount,
    so.payment_status,
    CURRENT_DATE - so.order_date AS days_open,
    e.first_name || ' ' || e.last_name AS sales_rep
FROM sales_orders so
JOIN customers c ON so.customer_id = c.id
LEFT JOIN employees e ON so.sales_rep_id = e.id
WHERE so.status NOT IN ('delivered', 'cancelled', 'refunded')
ORDER BY so.order_date;

-- Accounts receivable aging
CREATE OR REPLACE VIEW vw_ar_aging AS
SELECT
    i.id AS invoice_id,
    i.invoice_number,
    c.id AS customer_id,
    COALESCE(c.company_name, c.first_name || ' ' || c.last_name) AS customer_name,
    i.invoice_date,
    i.due_date,
    i.total_amount,
    i.amount_paid,
    i.balance_due,
    CURRENT_DATE - i.due_date AS days_past_due,
    CASE
        WHEN CURRENT_DATE <= i.due_date THEN 'Current'
        WHEN CURRENT_DATE - i.due_date <= 30 THEN '1-30 Days'
        WHEN CURRENT_DATE - i.due_date <= 60 THEN '31-60 Days'
        WHEN CURRENT_DATE - i.due_date <= 90 THEN '61-90 Days'
        ELSE 'Over 90 Days'
    END AS aging_bucket
FROM invoices i
JOIN customers c ON i.customer_id = c.id
WHERE i.balance_due > 0 AND i.status NOT IN ('void', 'draft')
ORDER BY i.due_date;

-- End of schema
