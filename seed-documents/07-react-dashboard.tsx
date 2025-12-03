// Enterprise Analytics Dashboard Application
// A comprehensive React TypeScript dashboard with real-time data visualization,
// user management, and advanced filtering capabilities.

import React, { useState, useEffect, useCallback, useMemo, useRef, createContext, useContext } from 'react';
import { createRoot } from 'react-dom/client';

// ============================================================================
// Type Definitions
// ============================================================================

interface User {
  id: string;
  email: string;
  firstName: string;
  lastName: string;
  role: 'admin' | 'manager' | 'analyst' | 'viewer';
  department: string;
  createdAt: Date;
  lastLogin: Date | null;
  preferences: UserPreferences;
  permissions: Permission[];
}

interface UserPreferences {
  theme: 'light' | 'dark' | 'system';
  language: string;
  timezone: string;
  notifications: NotificationSettings;
  dashboardLayout: DashboardLayout;
}

interface NotificationSettings {
  email: boolean;
  push: boolean;
  sms: boolean;
  frequency: 'realtime' | 'hourly' | 'daily' | 'weekly';
  categories: string[];
}

interface DashboardLayout {
  widgets: WidgetConfig[];
  columns: number;
  compactMode: boolean;
}

interface WidgetConfig {
  id: string;
  type: WidgetType;
  title: string;
  position: { x: number; y: number; w: number; h: number };
  config: Record<string, unknown>;
  refreshInterval: number;
}

type WidgetType = 'chart' | 'table' | 'metric' | 'map' | 'timeline' | 'heatmap';

interface Permission {
  resource: string;
  actions: ('read' | 'write' | 'delete' | 'admin')[];
}

interface MetricData {
  id: string;
  name: string;
  value: number;
  previousValue: number;
  unit: string;
  trend: 'up' | 'down' | 'stable';
  sparkline: number[];
  lastUpdated: Date;
}

interface ChartDataPoint {
  timestamp: Date;
  value: number;
  category: string;
  metadata?: Record<string, unknown>;
}

interface ChartSeries {
  id: string;
  name: string;
  color: string;
  data: ChartDataPoint[];
  visible: boolean;
}

interface FilterConfig {
  field: string;
  operator: 'eq' | 'ne' | 'gt' | 'lt' | 'gte' | 'lte' | 'contains' | 'in' | 'between';
  value: unknown;
}

interface SortConfig {
  field: string;
  direction: 'asc' | 'desc';
}

interface PaginationConfig {
  page: number;
  pageSize: number;
  total: number;
}

interface ApiResponse<T> {
  data: T;
  meta: {
    timestamp: Date;
    requestId: string;
    pagination?: PaginationConfig;
  };
  errors?: ApiError[];
}

interface ApiError {
  code: string;
  message: string;
  field?: string;
}

interface WebSocketMessage {
  type: 'metric_update' | 'alert' | 'notification' | 'system';
  payload: unknown;
  timestamp: Date;
}

// ============================================================================
// Context Providers
// ============================================================================

interface AuthContextType {
  user: User | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  login: (email: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  refreshToken: () => Promise<void>;
  updatePreferences: (preferences: Partial<UserPreferences>) => Promise<void>;
}

const AuthContext = createContext<AuthContextType | null>(null);

export const useAuth = (): AuthContextType => {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
};

interface ThemeContextType {
  theme: 'light' | 'dark';
  toggleTheme: () => void;
  colors: ThemeColors;
}

interface ThemeColors {
  primary: string;
  secondary: string;
  background: string;
  surface: string;
  text: string;
  textSecondary: string;
  border: string;
  success: string;
  warning: string;
  error: string;
  info: string;
}

const lightTheme: ThemeColors = {
  primary: '#3b82f6',
  secondary: '#8b5cf6',
  background: '#f8fafc',
  surface: '#ffffff',
  text: '#1e293b',
  textSecondary: '#64748b',
  border: '#e2e8f0',
  success: '#22c55e',
  warning: '#f59e0b',
  error: '#ef4444',
  info: '#06b6d4',
};

const darkTheme: ThemeColors = {
  primary: '#60a5fa',
  secondary: '#a78bfa',
  background: '#0f172a',
  surface: '#1e293b',
  text: '#f1f5f9',
  textSecondary: '#94a3b8',
  border: '#334155',
  success: '#4ade80',
  warning: '#fbbf24',
  error: '#f87171',
  info: '#22d3ee',
};

const ThemeContext = createContext<ThemeContextType | null>(null);

export const useTheme = (): ThemeContextType => {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error('useTheme must be used within a ThemeProvider');
  }
  return context;
};

// ============================================================================
// Custom Hooks
// ============================================================================

function useWebSocket(url: string, onMessage: (msg: WebSocketMessage) => void) {
  const wsRef = useRef<WebSocket | null>(null);
  const reconnectTimeoutRef = useRef<NodeJS.Timeout>();
  const [isConnected, setIsConnected] = useState(false);
  const [connectionAttempts, setConnectionAttempts] = useState(0);

  const connect = useCallback(() => {
    if (wsRef.current?.readyState === WebSocket.OPEN) return;

    const ws = new WebSocket(url);

    ws.onopen = () => {
      setIsConnected(true);
      setConnectionAttempts(0);
      console.log('WebSocket connected');
    };

    ws.onmessage = (event) => {
      try {
        const message: WebSocketMessage = JSON.parse(event.data);
        onMessage(message);
      } catch (error) {
        console.error('Failed to parse WebSocket message:', error);
      }
    };

    ws.onclose = (event) => {
      setIsConnected(false);
      console.log('WebSocket disconnected:', event.code, event.reason);

      // Exponential backoff reconnection
      const delay = Math.min(1000 * Math.pow(2, connectionAttempts), 30000);
      reconnectTimeoutRef.current = setTimeout(() => {
        setConnectionAttempts((prev) => prev + 1);
        connect();
      }, delay);
    };

    ws.onerror = (error) => {
      console.error('WebSocket error:', error);
    };

    wsRef.current = ws;
  }, [url, onMessage, connectionAttempts]);

  useEffect(() => {
    connect();

    return () => {
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current);
      }
      wsRef.current?.close();
    };
  }, [connect]);

  const sendMessage = useCallback((message: unknown) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify(message));
    }
  }, []);

  return { isConnected, sendMessage };
}

function useDebounce<T>(value: T, delay: number): T {
  const [debouncedValue, setDebouncedValue] = useState(value);

  useEffect(() => {
    const handler = setTimeout(() => {
      setDebouncedValue(value);
    }, delay);

    return () => {
      clearTimeout(handler);
    };
  }, [value, delay]);

  return debouncedValue;
}

function useLocalStorage<T>(key: string, initialValue: T): [T, (value: T) => void] {
  const [storedValue, setStoredValue] = useState<T>(() => {
    try {
      const item = window.localStorage.getItem(key);
      return item ? JSON.parse(item) : initialValue;
    } catch (error) {
      console.error('Error reading from localStorage:', error);
      return initialValue;
    }
  });

  const setValue = useCallback(
    (value: T) => {
      try {
        setStoredValue(value);
        window.localStorage.setItem(key, JSON.stringify(value));
      } catch (error) {
        console.error('Error writing to localStorage:', error);
      }
    },
    [key]
  );

  return [storedValue, setValue];
}

function usePagination<T>(items: T[], pageSize: number) {
  const [currentPage, setCurrentPage] = useState(1);

  const totalPages = Math.ceil(items.length / pageSize);

  const paginatedItems = useMemo(() => {
    const start = (currentPage - 1) * pageSize;
    return items.slice(start, start + pageSize);
  }, [items, currentPage, pageSize]);

  const goToPage = useCallback(
    (page: number) => {
      const validPage = Math.max(1, Math.min(page, totalPages));
      setCurrentPage(validPage);
    },
    [totalPages]
  );

  const nextPage = useCallback(() => {
    goToPage(currentPage + 1);
  }, [currentPage, goToPage]);

  const prevPage = useCallback(() => {
    goToPage(currentPage - 1);
  }, [currentPage, goToPage]);

  return {
    items: paginatedItems,
    currentPage,
    totalPages,
    goToPage,
    nextPage,
    prevPage,
    hasNextPage: currentPage < totalPages,
    hasPrevPage: currentPage > 1,
  };
}

function useAsync<T>(asyncFunction: () => Promise<T>, dependencies: unknown[] = []) {
  const [state, setState] = useState<{
    data: T | null;
    loading: boolean;
    error: Error | null;
  }>({
    data: null,
    loading: true,
    error: null,
  });

  useEffect(() => {
    let mounted = true;

    setState((prev) => ({ ...prev, loading: true, error: null }));

    asyncFunction()
      .then((data) => {
        if (mounted) {
          setState({ data, loading: false, error: null });
        }
      })
      .catch((error) => {
        if (mounted) {
          setState({ data: null, loading: false, error });
        }
      });

    return () => {
      mounted = false;
    };
  }, dependencies);

  return state;
}

// ============================================================================
// API Service
// ============================================================================

class ApiService {
  private baseUrl: string;
  private accessToken: string | null = null;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
  }

  setAccessToken(token: string | null) {
    this.accessToken = token;
  }

  private async request<T>(
    endpoint: string,
    options: RequestInit = {}
  ): Promise<ApiResponse<T>> {
    const headers: HeadersInit = {
      'Content-Type': 'application/json',
      ...options.headers,
    };

    if (this.accessToken) {
      (headers as Record<string, string>)['Authorization'] = `Bearer ${this.accessToken}`;
    }

    const response = await fetch(`${this.baseUrl}${endpoint}`, {
      ...options,
      headers,
    });

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      throw new ApiServiceError(
        response.status,
        errorData.message || 'Request failed',
        errorData.errors
      );
    }

    return response.json();
  }

  async get<T>(endpoint: string, params?: Record<string, string>): Promise<ApiResponse<T>> {
    const url = params
      ? `${endpoint}?${new URLSearchParams(params).toString()}`
      : endpoint;
    return this.request<T>(url);
  }

  async post<T>(endpoint: string, data: unknown): Promise<ApiResponse<T>> {
    return this.request<T>(endpoint, {
      method: 'POST',
      body: JSON.stringify(data),
    });
  }

  async put<T>(endpoint: string, data: unknown): Promise<ApiResponse<T>> {
    return this.request<T>(endpoint, {
      method: 'PUT',
      body: JSON.stringify(data),
    });
  }

  async patch<T>(endpoint: string, data: unknown): Promise<ApiResponse<T>> {
    return this.request<T>(endpoint, {
      method: 'PATCH',
      body: JSON.stringify(data),
    });
  }

  async delete<T>(endpoint: string): Promise<ApiResponse<T>> {
    return this.request<T>(endpoint, { method: 'DELETE' });
  }
}

class ApiServiceError extends Error {
  constructor(
    public status: number,
    message: string,
    public errors?: ApiError[]
  ) {
    super(message);
    this.name = 'ApiServiceError';
  }
}

const api = new ApiService('/api/v1');

// ============================================================================
// Components
// ============================================================================

interface MetricCardProps {
  metric: MetricData;
  onClick?: () => void;
}

const MetricCard: React.FC<MetricCardProps> = ({ metric, onClick }) => {
  const { colors } = useTheme();

  const percentChange = useMemo(() => {
    if (metric.previousValue === 0) return 0;
    return ((metric.value - metric.previousValue) / metric.previousValue) * 100;
  }, [metric.value, metric.previousValue]);

  const trendColor = useMemo(() => {
    switch (metric.trend) {
      case 'up':
        return colors.success;
      case 'down':
        return colors.error;
      default:
        return colors.textSecondary;
    }
  }, [metric.trend, colors]);

  const formatValue = (value: number, unit: string): string => {
    if (unit === 'currency') {
      return new Intl.NumberFormat('en-US', {
        style: 'currency',
        currency: 'USD',
        minimumFractionDigits: 0,
        maximumFractionDigits: 0,
      }).format(value);
    }
    if (unit === 'percent') {
      return `${value.toFixed(1)}%`;
    }
    if (value >= 1000000) {
      return `${(value / 1000000).toFixed(1)}M`;
    }
    if (value >= 1000) {
      return `${(value / 1000).toFixed(1)}K`;
    }
    return value.toFixed(0);
  };

  return (
    <div
      onClick={onClick}
      style={{
        backgroundColor: colors.surface,
        borderRadius: '12px',
        padding: '20px',
        border: `1px solid ${colors.border}`,
        cursor: onClick ? 'pointer' : 'default',
        transition: 'transform 0.2s, box-shadow 0.2s',
      }}
      onMouseEnter={(e) => {
        if (onClick) {
          e.currentTarget.style.transform = 'translateY(-2px)';
          e.currentTarget.style.boxShadow = '0 4px 12px rgba(0,0,0,0.1)';
        }
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.transform = 'translateY(0)';
        e.currentTarget.style.boxShadow = 'none';
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <h3 style={{ color: colors.textSecondary, fontSize: '14px', margin: 0 }}>
            {metric.name}
          </h3>
          <p style={{ color: colors.text, fontSize: '28px', fontWeight: 600, margin: '8px 0' }}>
            {formatValue(metric.value, metric.unit)}
          </p>
          <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
            <span style={{ color: trendColor, fontSize: '14px' }}>
              {metric.trend === 'up' ? '↑' : metric.trend === 'down' ? '↓' : '→'}
              {Math.abs(percentChange).toFixed(1)}%
            </span>
            <span style={{ color: colors.textSecondary, fontSize: '12px' }}>
              vs last period
            </span>
          </div>
        </div>
        <SparklineChart data={metric.sparkline} color={trendColor} />
      </div>
    </div>
  );
};

interface SparklineChartProps {
  data: number[];
  color: string;
  width?: number;
  height?: number;
}

const SparklineChart: React.FC<SparklineChartProps> = ({
  data,
  color,
  width = 80,
  height = 40,
}) => {
  const pathData = useMemo(() => {
    if (data.length < 2) return '';

    const min = Math.min(...data);
    const max = Math.max(...data);
    const range = max - min || 1;

    const points = data.map((value, index) => {
      const x = (index / (data.length - 1)) * width;
      const y = height - ((value - min) / range) * height;
      return `${x},${y}`;
    });

    return `M ${points.join(' L ')}`;
  }, [data, width, height]);

  return (
    <svg width={width} height={height} style={{ overflow: 'visible' }}>
      <path d={pathData} fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" />
    </svg>
  );
};

interface DataTableProps<T> {
  data: T[];
  columns: ColumnDef<T>[];
  onRowClick?: (row: T) => void;
  sortConfig?: SortConfig;
  onSort?: (config: SortConfig) => void;
  loading?: boolean;
  emptyMessage?: string;
}

interface ColumnDef<T> {
  key: keyof T | string;
  header: string;
  width?: string;
  sortable?: boolean;
  render?: (value: unknown, row: T) => React.ReactNode;
}

function DataTable<T extends { id: string }>({
  data,
  columns,
  onRowClick,
  sortConfig,
  onSort,
  loading = false,
  emptyMessage = 'No data available',
}: DataTableProps<T>) {
  const { colors } = useTheme();

  const handleSort = (column: ColumnDef<T>) => {
    if (!column.sortable || !onSort) return;

    const key = column.key as string;
    const direction =
      sortConfig?.field === key && sortConfig.direction === 'asc' ? 'desc' : 'asc';
    onSort({ field: key, direction });
  };

  const getCellValue = (row: T, key: keyof T | string): unknown => {
    if (typeof key === 'string' && key.includes('.')) {
      return key.split('.').reduce((obj: unknown, k) => {
        return obj && typeof obj === 'object' ? (obj as Record<string, unknown>)[k] : undefined;
      }, row);
    }
    return row[key as keyof T];
  };

  if (loading) {
    return (
      <div
        style={{
          display: 'flex',
          justifyContent: 'center',
          alignItems: 'center',
          padding: '40px',
          color: colors.textSecondary,
        }}
      >
        <LoadingSpinner size={32} />
        <span style={{ marginLeft: '12px' }}>Loading...</span>
      </div>
    );
  }

  return (
    <div style={{ overflowX: 'auto' }}>
      <table
        style={{
          width: '100%',
          borderCollapse: 'collapse',
          fontSize: '14px',
        }}
      >
        <thead>
          <tr>
            {columns.map((column) => (
              <th
                key={column.key as string}
                onClick={() => handleSort(column)}
                style={{
                  textAlign: 'left',
                  padding: '12px 16px',
                  borderBottom: `2px solid ${colors.border}`,
                  color: colors.textSecondary,
                  fontWeight: 600,
                  cursor: column.sortable ? 'pointer' : 'default',
                  width: column.width,
                  userSelect: 'none',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                  {column.header}
                  {column.sortable && sortConfig?.field === column.key && (
                    <span>{sortConfig.direction === 'asc' ? '↑' : '↓'}</span>
                  )}
                </div>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {data.length === 0 ? (
            <tr>
              <td
                colSpan={columns.length}
                style={{
                  textAlign: 'center',
                  padding: '40px',
                  color: colors.textSecondary,
                }}
              >
                {emptyMessage}
              </td>
            </tr>
          ) : (
            data.map((row) => (
              <tr
                key={row.id}
                onClick={() => onRowClick?.(row)}
                style={{
                  cursor: onRowClick ? 'pointer' : 'default',
                  transition: 'background-color 0.15s',
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.backgroundColor = colors.border;
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.backgroundColor = 'transparent';
                }}
              >
                {columns.map((column) => {
                  const value = getCellValue(row, column.key);
                  return (
                    <td
                      key={column.key as string}
                      style={{
                        padding: '12px 16px',
                        borderBottom: `1px solid ${colors.border}`,
                        color: colors.text,
                      }}
                    >
                      {column.render ? column.render(value, row) : String(value ?? '')}
                    </td>
                  );
                })}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}

interface LoadingSpinnerProps {
  size?: number;
  color?: string;
}

const LoadingSpinner: React.FC<LoadingSpinnerProps> = ({ size = 24, color }) => {
  const { colors } = useTheme();
  const spinnerColor = color || colors.primary;

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      style={{
        animation: 'spin 1s linear infinite',
      }}
    >
      <style>
        {`
          @keyframes spin {
            from { transform: rotate(0deg); }
            to { transform: rotate(360deg); }
          }
        `}
      </style>
      <circle
        cx="12"
        cy="12"
        r="10"
        stroke={spinnerColor}
        strokeWidth="3"
        fill="none"
        strokeDasharray="31.416"
        strokeDashoffset="10"
        strokeLinecap="round"
      />
    </svg>
  );
};

interface ButtonProps {
  children: React.ReactNode;
  variant?: 'primary' | 'secondary' | 'outline' | 'ghost' | 'danger';
  size?: 'sm' | 'md' | 'lg';
  disabled?: boolean;
  loading?: boolean;
  onClick?: () => void;
  type?: 'button' | 'submit' | 'reset';
  fullWidth?: boolean;
}

const Button: React.FC<ButtonProps> = ({
  children,
  variant = 'primary',
  size = 'md',
  disabled = false,
  loading = false,
  onClick,
  type = 'button',
  fullWidth = false,
}) => {
  const { colors } = useTheme();

  const sizeStyles = {
    sm: { padding: '6px 12px', fontSize: '12px' },
    md: { padding: '10px 16px', fontSize: '14px' },
    lg: { padding: '14px 24px', fontSize: '16px' },
  };

  const variantStyles = {
    primary: {
      backgroundColor: colors.primary,
      color: '#ffffff',
      border: 'none',
    },
    secondary: {
      backgroundColor: colors.secondary,
      color: '#ffffff',
      border: 'none',
    },
    outline: {
      backgroundColor: 'transparent',
      color: colors.primary,
      border: `1px solid ${colors.primary}`,
    },
    ghost: {
      backgroundColor: 'transparent',
      color: colors.text,
      border: 'none',
    },
    danger: {
      backgroundColor: colors.error,
      color: '#ffffff',
      border: 'none',
    },
  };

  return (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled || loading}
      style={{
        ...sizeStyles[size],
        ...variantStyles[variant],
        borderRadius: '8px',
        fontWeight: 500,
        cursor: disabled || loading ? 'not-allowed' : 'pointer',
        opacity: disabled ? 0.5 : 1,
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: '8px',
        width: fullWidth ? '100%' : 'auto',
        transition: 'opacity 0.15s, transform 0.15s',
      }}
    >
      {loading && <LoadingSpinner size={16} color="currentColor" />}
      {children}
    </button>
  );
};

interface ModalProps {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
  size?: 'sm' | 'md' | 'lg' | 'xl';
  footer?: React.ReactNode;
}

const Modal: React.FC<ModalProps> = ({
  isOpen,
  onClose,
  title,
  children,
  size = 'md',
  footer,
}) => {
  const { colors } = useTheme();

  const sizeWidths = {
    sm: '400px',
    md: '560px',
    lg: '720px',
    xl: '960px',
  };

  useEffect(() => {
    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };

    if (isOpen) {
      document.addEventListener('keydown', handleEscape);
      document.body.style.overflow = 'hidden';
    }

    return () => {
      document.removeEventListener('keydown', handleEscape);
      document.body.style.overflow = 'unset';
    };
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  return (
    <div
      style={{
        position: 'fixed',
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        backgroundColor: 'rgba(0, 0, 0, 0.5)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 1000,
      }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        style={{
          backgroundColor: colors.surface,
          borderRadius: '16px',
          width: '90%',
          maxWidth: sizeWidths[size],
          maxHeight: '90vh',
          display: 'flex',
          flexDirection: 'column',
          boxShadow: '0 20px 40px rgba(0, 0, 0, 0.2)',
        }}
      >
        <div
          style={{
            padding: '20px 24px',
            borderBottom: `1px solid ${colors.border}`,
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
          }}
        >
          <h2 style={{ margin: 0, color: colors.text, fontSize: '18px', fontWeight: 600 }}>
            {title}
          </h2>
          <button
            onClick={onClose}
            style={{
              background: 'none',
              border: 'none',
              cursor: 'pointer',
              padding: '4px',
              color: colors.textSecondary,
              fontSize: '20px',
            }}
          >
            ×
          </button>
        </div>
        <div style={{ padding: '24px', overflowY: 'auto', flex: 1 }}>{children}</div>
        {footer && (
          <div
            style={{
              padding: '16px 24px',
              borderTop: `1px solid ${colors.border}`,
              display: 'flex',
              justifyContent: 'flex-end',
              gap: '12px',
            }}
          >
            {footer}
          </div>
        )}
      </div>
    </div>
  );
};

interface SearchInputProps {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  debounceMs?: number;
}

const SearchInput: React.FC<SearchInputProps> = ({
  value,
  onChange,
  placeholder = 'Search...',
  debounceMs = 300,
}) => {
  const { colors } = useTheme();
  const [localValue, setLocalValue] = useState(value);
  const debouncedValue = useDebounce(localValue, debounceMs);

  useEffect(() => {
    onChange(debouncedValue);
  }, [debouncedValue, onChange]);

  useEffect(() => {
    setLocalValue(value);
  }, [value]);

  return (
    <div style={{ position: 'relative' }}>
      <input
        type="text"
        value={localValue}
        onChange={(e) => setLocalValue(e.target.value)}
        placeholder={placeholder}
        style={{
          width: '100%',
          padding: '10px 16px 10px 40px',
          borderRadius: '8px',
          border: `1px solid ${colors.border}`,
          backgroundColor: colors.surface,
          color: colors.text,
          fontSize: '14px',
          outline: 'none',
          transition: 'border-color 0.15s',
        }}
        onFocus={(e) => {
          e.target.style.borderColor = colors.primary;
        }}
        onBlur={(e) => {
          e.target.style.borderColor = colors.border;
        }}
      />
      <span
        style={{
          position: 'absolute',
          left: '12px',
          top: '50%',
          transform: 'translateY(-50%)',
          color: colors.textSecondary,
        }}
      >
        🔍
      </span>
    </div>
  );
};

interface FilterPanelProps {
  filters: FilterConfig[];
  onFilterChange: (filters: FilterConfig[]) => void;
  availableFields: { key: string; label: string; type: 'string' | 'number' | 'date' | 'enum' }[];
}

const FilterPanel: React.FC<FilterPanelProps> = ({
  filters,
  onFilterChange,
  availableFields,
}) => {
  const { colors } = useTheme();

  const addFilter = () => {
    onFilterChange([
      ...filters,
      { field: availableFields[0]?.key || '', operator: 'eq', value: '' },
    ]);
  };

  const updateFilter = (index: number, updates: Partial<FilterConfig>) => {
    const newFilters = [...filters];
    newFilters[index] = { ...newFilters[index], ...updates };
    onFilterChange(newFilters);
  };

  const removeFilter = (index: number) => {
    onFilterChange(filters.filter((_, i) => i !== index));
  };

  const operators = [
    { value: 'eq', label: 'equals' },
    { value: 'ne', label: 'not equals' },
    { value: 'gt', label: 'greater than' },
    { value: 'lt', label: 'less than' },
    { value: 'contains', label: 'contains' },
  ];

  return (
    <div
      style={{
        backgroundColor: colors.surface,
        borderRadius: '12px',
        padding: '16px',
        border: `1px solid ${colors.border}`,
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '16px' }}>
        <h3 style={{ margin: 0, color: colors.text, fontSize: '14px', fontWeight: 600 }}>
          Filters
        </h3>
        <Button variant="ghost" size="sm" onClick={addFilter}>
          + Add Filter
        </Button>
      </div>

      {filters.length === 0 ? (
        <p style={{ color: colors.textSecondary, fontSize: '14px', margin: 0 }}>
          No filters applied
        </p>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
          {filters.map((filter, index) => (
            <div key={index} style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
              <select
                value={filter.field}
                onChange={(e) => updateFilter(index, { field: e.target.value })}
                style={{
                  padding: '8px 12px',
                  borderRadius: '6px',
                  border: `1px solid ${colors.border}`,
                  backgroundColor: colors.background,
                  color: colors.text,
                  fontSize: '14px',
                  flex: 1,
                }}
              >
                {availableFields.map((field) => (
                  <option key={field.key} value={field.key}>
                    {field.label}
                  </option>
                ))}
              </select>

              <select
                value={filter.operator}
                onChange={(e) => updateFilter(index, { operator: e.target.value as FilterConfig['operator'] })}
                style={{
                  padding: '8px 12px',
                  borderRadius: '6px',
                  border: `1px solid ${colors.border}`,
                  backgroundColor: colors.background,
                  color: colors.text,
                  fontSize: '14px',
                  width: '140px',
                }}
              >
                {operators.map((op) => (
                  <option key={op.value} value={op.value}>
                    {op.label}
                  </option>
                ))}
              </select>

              <input
                type="text"
                value={String(filter.value)}
                onChange={(e) => updateFilter(index, { value: e.target.value })}
                placeholder="Value"
                style={{
                  padding: '8px 12px',
                  borderRadius: '6px',
                  border: `1px solid ${colors.border}`,
                  backgroundColor: colors.background,
                  color: colors.text,
                  fontSize: '14px',
                  flex: 1,
                }}
              />

              <Button variant="ghost" size="sm" onClick={() => removeFilter(index)}>
                ×
              </Button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

// ============================================================================
// Page Components
// ============================================================================

interface DashboardPageProps {
  user: User;
}

const DashboardPage: React.FC<DashboardPageProps> = ({ user }) => {
  const { colors } = useTheme();
  const [metrics, setMetrics] = useState<MetricData[]>([]);
  const [chartData, setChartData] = useState<ChartSeries[]>([]);
  const [selectedTimeRange, setSelectedTimeRange] = useState<'1h' | '24h' | '7d' | '30d'>('24h');
  const [isLoading, setIsLoading] = useState(true);

  const handleWebSocketMessage = useCallback((message: WebSocketMessage) => {
    if (message.type === 'metric_update') {
      const update = message.payload as { metricId: string; value: number };
      setMetrics((prev) =>
        prev.map((m) =>
          m.id === update.metricId
            ? {
                ...m,
                previousValue: m.value,
                value: update.value,
                lastUpdated: new Date(),
                sparkline: [...m.sparkline.slice(1), update.value],
              }
            : m
        )
      );
    }
  }, []);

  const { isConnected } = useWebSocket(
    `wss://api.example.com/ws?token=${user.id}`,
    handleWebSocketMessage
  );

  useEffect(() => {
    const fetchDashboardData = async () => {
      setIsLoading(true);
      try {
        const [metricsResponse, chartResponse] = await Promise.all([
          api.get<MetricData[]>('/metrics', { timeRange: selectedTimeRange }),
          api.get<ChartSeries[]>('/charts/overview', { timeRange: selectedTimeRange }),
        ]);

        setMetrics(metricsResponse.data);
        setChartData(chartResponse.data);
      } catch (error) {
        console.error('Failed to fetch dashboard data:', error);
      } finally {
        setIsLoading(false);
      }
    };

    fetchDashboardData();
  }, [selectedTimeRange]);

  const timeRangeOptions = [
    { value: '1h', label: 'Last Hour' },
    { value: '24h', label: 'Last 24 Hours' },
    { value: '7d', label: 'Last 7 Days' },
    { value: '30d', label: 'Last 30 Days' },
  ];

  return (
    <div style={{ padding: '24px' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '24px' }}>
        <div>
          <h1 style={{ margin: 0, color: colors.text, fontSize: '24px', fontWeight: 600 }}>
            Dashboard
          </h1>
          <p style={{ margin: '4px 0 0', color: colors.textSecondary, fontSize: '14px' }}>
            Welcome back, {user.firstName}
          </p>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
            <span
              style={{
                width: '8px',
                height: '8px',
                borderRadius: '50%',
                backgroundColor: isConnected ? colors.success : colors.error,
              }}
            />
            <span style={{ color: colors.textSecondary, fontSize: '12px' }}>
              {isConnected ? 'Live' : 'Disconnected'}
            </span>
          </div>

          <select
            value={selectedTimeRange}
            onChange={(e) => setSelectedTimeRange(e.target.value as typeof selectedTimeRange)}
            style={{
              padding: '8px 16px',
              borderRadius: '8px',
              border: `1px solid ${colors.border}`,
              backgroundColor: colors.surface,
              color: colors.text,
              fontSize: '14px',
              cursor: 'pointer',
            }}
          >
            {timeRangeOptions.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
        </div>
      </div>

      {isLoading ? (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '60px' }}>
          <LoadingSpinner size={40} />
        </div>
      ) : (
        <>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))',
              gap: '16px',
              marginBottom: '24px',
            }}
          >
            {metrics.map((metric) => (
              <MetricCard key={metric.id} metric={metric} />
            ))}
          </div>

          <div
            style={{
              backgroundColor: colors.surface,
              borderRadius: '12px',
              padding: '24px',
              border: `1px solid ${colors.border}`,
            }}
          >
            <h2 style={{ margin: '0 0 16px', color: colors.text, fontSize: '18px', fontWeight: 600 }}>
              Performance Overview
            </h2>
            <div style={{ height: '400px', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <p style={{ color: colors.textSecondary }}>Chart visualization would render here</p>
            </div>
          </div>
        </>
      )}
    </div>
  );
};

// ============================================================================
// Application Shell
// ============================================================================

interface NavigationItem {
  id: string;
  label: string;
  icon: string;
  path: string;
  requiredPermission?: string;
}

const navigationItems: NavigationItem[] = [
  { id: 'dashboard', label: 'Dashboard', icon: '📊', path: '/dashboard' },
  { id: 'analytics', label: 'Analytics', icon: '📈', path: '/analytics' },
  { id: 'reports', label: 'Reports', icon: '📋', path: '/reports' },
  { id: 'users', label: 'Users', icon: '👥', path: '/users', requiredPermission: 'users' },
  { id: 'settings', label: 'Settings', icon: '⚙️', path: '/settings' },
];

const AppShell: React.FC = () => {
  const { user, logout, isLoading: authLoading } = useAuth();
  const { colors, toggleTheme, theme } = useTheme();
  const [currentPath, setCurrentPath] = useState('/dashboard');
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);

  const hasPermission = useCallback(
    (resource: string) => {
      if (!user) return false;
      if (user.role === 'admin') return true;
      return user.permissions.some(
        (p) => p.resource === resource && p.actions.includes('read')
      );
    },
    [user]
  );

  const visibleNavItems = useMemo(
    () =>
      navigationItems.filter(
        (item) => !item.requiredPermission || hasPermission(item.requiredPermission)
      ),
    [hasPermission]
  );

  if (authLoading) {
    return (
      <div
        style={{
          height: '100vh',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          backgroundColor: colors.background,
        }}
      >
        <LoadingSpinner size={48} />
      </div>
    );
  }

  if (!user) {
    return <LoginPage />;
  }

  return (
    <div style={{ display: 'flex', height: '100vh', backgroundColor: colors.background }}>
      {/* Sidebar */}
      <aside
        style={{
          width: sidebarCollapsed ? '64px' : '240px',
          backgroundColor: colors.surface,
          borderRight: `1px solid ${colors.border}`,
          display: 'flex',
          flexDirection: 'column',
          transition: 'width 0.2s',
        }}
      >
        <div
          style={{
            padding: '16px',
            borderBottom: `1px solid ${colors.border}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: sidebarCollapsed ? 'center' : 'space-between',
          }}
        >
          {!sidebarCollapsed && (
            <span style={{ color: colors.text, fontWeight: 600, fontSize: '18px' }}>
              Analytics
            </span>
          )}
          <button
            onClick={() => setSidebarCollapsed(!sidebarCollapsed)}
            style={{
              background: 'none',
              border: 'none',
              cursor: 'pointer',
              padding: '4px',
              color: colors.textSecondary,
            }}
          >
            {sidebarCollapsed ? '→' : '←'}
          </button>
        </div>

        <nav style={{ flex: 1, padding: '8px' }}>
          {visibleNavItems.map((item) => (
            <button
              key={item.id}
              onClick={() => setCurrentPath(item.path)}
              style={{
                width: '100%',
                padding: sidebarCollapsed ? '12px' : '12px 16px',
                marginBottom: '4px',
                borderRadius: '8px',
                border: 'none',
                backgroundColor: currentPath === item.path ? colors.primary + '20' : 'transparent',
                color: currentPath === item.path ? colors.primary : colors.text,
                display: 'flex',
                alignItems: 'center',
                gap: '12px',
                cursor: 'pointer',
                justifyContent: sidebarCollapsed ? 'center' : 'flex-start',
                transition: 'background-color 0.15s',
              }}
            >
              <span style={{ fontSize: '18px' }}>{item.icon}</span>
              {!sidebarCollapsed && (
                <span style={{ fontSize: '14px', fontWeight: 500 }}>{item.label}</span>
              )}
            </button>
          ))}
        </nav>

        <div
          style={{
            padding: '16px',
            borderTop: `1px solid ${colors.border}`,
          }}
        >
          <button
            onClick={toggleTheme}
            style={{
              width: '100%',
              padding: '8px',
              borderRadius: '8px',
              border: 'none',
              backgroundColor: 'transparent',
              color: colors.textSecondary,
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              justifyContent: sidebarCollapsed ? 'center' : 'flex-start',
              gap: '8px',
            }}
          >
            {theme === 'light' ? '🌙' : '☀️'}
            {!sidebarCollapsed && (
              <span style={{ fontSize: '14px' }}>
                {theme === 'light' ? 'Dark Mode' : 'Light Mode'}
              </span>
            )}
          </button>
        </div>
      </aside>

      {/* Main Content */}
      <main style={{ flex: 1, overflow: 'auto' }}>
        {/* Header */}
        <header
          style={{
            height: '64px',
            backgroundColor: colors.surface,
            borderBottom: `1px solid ${colors.border}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '0 24px',
          }}
        >
          <SearchInput
            value=""
            onChange={() => {}}
            placeholder="Search anything..."
          />

          <div style={{ display: 'flex', alignItems: 'center', gap: '16px' }}>
            <button
              style={{
                background: 'none',
                border: 'none',
                cursor: 'pointer',
                padding: '8px',
                color: colors.textSecondary,
                position: 'relative',
              }}
            >
              🔔
              <span
                style={{
                  position: 'absolute',
                  top: '4px',
                  right: '4px',
                  width: '8px',
                  height: '8px',
                  backgroundColor: colors.error,
                  borderRadius: '50%',
                }}
              />
            </button>

            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              <div
                style={{
                  width: '36px',
                  height: '36px',
                  borderRadius: '50%',
                  backgroundColor: colors.primary,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  color: '#ffffff',
                  fontWeight: 600,
                }}
              >
                {user.firstName[0]}
                {user.lastName[0]}
              </div>
              <div>
                <p style={{ margin: 0, color: colors.text, fontSize: '14px', fontWeight: 500 }}>
                  {user.firstName} {user.lastName}
                </p>
                <p style={{ margin: 0, color: colors.textSecondary, fontSize: '12px' }}>
                  {user.role}
                </p>
              </div>
              <Button variant="ghost" size="sm" onClick={logout}>
                Logout
              </Button>
            </div>
          </div>
        </header>

        {/* Page Content */}
        <DashboardPage user={user} />
      </main>
    </div>
  );
};

const LoginPage: React.FC = () => {
  const { colors } = useTheme();
  const { login } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsLoading(true);
    setError(null);

    try {
      await login(email, password);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Login failed');
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div
      style={{
        height: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        backgroundColor: colors.background,
      }}
    >
      <div
        style={{
          width: '100%',
          maxWidth: '400px',
          padding: '40px',
          backgroundColor: colors.surface,
          borderRadius: '16px',
          border: `1px solid ${colors.border}`,
        }}
      >
        <h1
          style={{
            margin: '0 0 8px',
            color: colors.text,
            fontSize: '24px',
            fontWeight: 600,
            textAlign: 'center',
          }}
        >
          Welcome Back
        </h1>
        <p
          style={{
            margin: '0 0 32px',
            color: colors.textSecondary,
            fontSize: '14px',
            textAlign: 'center',
          }}
        >
          Sign in to your account to continue
        </p>

        <form onSubmit={handleSubmit}>
          {error && (
            <div
              style={{
                padding: '12px 16px',
                backgroundColor: colors.error + '20',
                borderRadius: '8px',
                marginBottom: '16px',
                color: colors.error,
                fontSize: '14px',
              }}
            >
              {error}
            </div>
          )}

          <div style={{ marginBottom: '16px' }}>
            <label
              style={{
                display: 'block',
                marginBottom: '8px',
                color: colors.text,
                fontSize: '14px',
                fontWeight: 500,
              }}
            >
              Email
            </label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
              style={{
                width: '100%',
                padding: '12px 16px',
                borderRadius: '8px',
                border: `1px solid ${colors.border}`,
                backgroundColor: colors.background,
                color: colors.text,
                fontSize: '14px',
                outline: 'none',
                boxSizing: 'border-box',
              }}
            />
          </div>

          <div style={{ marginBottom: '24px' }}>
            <label
              style={{
                display: 'block',
                marginBottom: '8px',
                color: colors.text,
                fontSize: '14px',
                fontWeight: 500,
              }}
            >
              Password
            </label>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              style={{
                width: '100%',
                padding: '12px 16px',
                borderRadius: '8px',
                border: `1px solid ${colors.border}`,
                backgroundColor: colors.background,
                color: colors.text,
                fontSize: '14px',
                outline: 'none',
                boxSizing: 'border-box',
              }}
            />
          </div>

          <Button type="submit" fullWidth loading={isLoading}>
            Sign In
          </Button>
        </form>
      </div>
    </div>
  );
};

// ============================================================================
// Application Entry Point
// ============================================================================

const App: React.FC = () => {
  const [theme, setTheme] = useLocalStorage<'light' | 'dark'>('theme', 'light');
  const [user, setUser] = useState<User | null>(null);
  const [isAuthLoading, setIsAuthLoading] = useState(true);

  useEffect(() => {
    // Check for existing session
    const checkAuth = async () => {
      try {
        const response = await api.get<User>('/auth/me');
        setUser(response.data);
      } catch {
        // Not authenticated
      } finally {
        setIsAuthLoading(false);
      }
    };

    checkAuth();
  }, []);

  const authContextValue: AuthContextType = {
    user,
    isAuthenticated: !!user,
    isLoading: isAuthLoading,
    login: async (email: string, password: string) => {
      const response = await api.post<{ user: User; token: string }>('/auth/login', {
        email,
        password,
      });
      api.setAccessToken(response.data.token);
      setUser(response.data.user);
    },
    logout: async () => {
      await api.post('/auth/logout', {});
      api.setAccessToken(null);
      setUser(null);
    },
    refreshToken: async () => {
      const response = await api.post<{ token: string }>('/auth/refresh', {});
      api.setAccessToken(response.data.token);
    },
    updatePreferences: async (preferences: Partial<UserPreferences>) => {
      const response = await api.patch<User>('/users/me/preferences', preferences);
      setUser(response.data);
    },
  };

  const themeContextValue: ThemeContextType = {
    theme,
    toggleTheme: () => setTheme(theme === 'light' ? 'dark' : 'light'),
    colors: theme === 'light' ? lightTheme : darkTheme,
  };

  return (
    <AuthContext.Provider value={authContextValue}>
      <ThemeContext.Provider value={themeContextValue}>
        <AppShell />
      </ThemeContext.Provider>
    </AuthContext.Provider>
  );
};

// Mount the application
const container = document.getElementById('root');
if (container) {
  const root = createRoot(container);
  root.render(<App />);
}

export default App;
