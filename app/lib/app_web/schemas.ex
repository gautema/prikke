defmodule PrikkeWeb.Schemas do
  @moduledoc """
  OpenAPI schema definitions for the Prikke API.
  """
  alias OpenApiSpex.Schema

  defmodule Task do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Task",
      description: "A scheduled task",
      type: :object,
      required: [:id, :name, :url, :schedule_type],
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Task ID"},
        name: %Schema{type: :string, description: "Task name"},
        url: %Schema{type: :string, format: :uri, description: "Webhook URL to call"},
        method: %Schema{
          type: :string,
          enum: ["GET", "POST", "PUT", "PATCH", "DELETE"],
          default: "GET"
        },
        headers: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string},
          description: "HTTP headers"
        },
        body: %Schema{
          type: :string,
          nullable: true,
          description: "Request body (for POST/PUT/PATCH)"
        },
        schedule_type: %Schema{
          type: :string,
          enum: ["cron", "once"],
          description: "Schedule type"
        },
        cron_expression: %Schema{
          type: :string,
          nullable: true,
          description: "Cron expression (for cron tasks)"
        },
        scheduled_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Scheduled time (for one-time tasks)"
        },
        enabled: %Schema{
          type: :boolean,
          default: true,
          description: "Whether the task is enabled"
        },
        muted: %Schema{
          type: :boolean,
          default: false,
          description: "Whether notifications are muted for this task"
        },
        timeout_ms: %Schema{
          type: :integer,
          default: 30000,
          description: "Request timeout in milliseconds"
        },
        retry_attempts: %Schema{
          type: :integer,
          default: 3,
          description: "Number of retry attempts for one-time tasks"
        },
        callback_url: %Schema{
          type: :string,
          format: :uri,
          nullable: true,
          description: "URL to receive POST with execution results"
        },
        expected_status_codes: %Schema{
          type: :string,
          nullable: true,
          description:
            "Comma-separated HTTP status codes that count as success (e.g. \"200,201\"). Empty means any 2xx."
        },
        expected_body_pattern: %Schema{
          type: :string,
          nullable: true,
          description:
            "Response body must contain this text to count as success. Empty means any body."
        },
        next_run_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Next scheduled run time"
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Last update timestamp"
        }
      },
      example: %{
        id: "019c0123-4567-7890-abcd-ef1234567890",
        name: "Daily cleanup",
        url: "https://example.com/api/cleanup",
        method: "POST",
        headers: %{"Content-Type" => "application/json"},
        body: ~s({"action": "cleanup"}),
        schedule_type: "cron",
        cron_expression: "0 0 * * *",
        enabled: true,
        timeout_ms: 30000,
        retry_attempts: 3,
        next_run_at: "2026-01-30T00:00:00Z",
        inserted_at: "2026-01-29T10:00:00Z",
        updated_at: "2026-01-29T10:00:00Z"
      }
    })
  end

  defmodule TaskRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TaskRequest",
      description: "Request body for creating or updating a task",
      type: :object,
      required: [:name, :url, :schedule_type],
      properties: %{
        name: %Schema{type: :string, description: "Task name"},
        url: %Schema{type: :string, format: :uri, description: "Webhook URL to call"},
        method: %Schema{
          type: :string,
          enum: ["GET", "POST", "PUT", "PATCH", "DELETE"],
          default: "GET"
        },
        headers: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        body: %Schema{type: :string, nullable: true},
        schedule_type: %Schema{type: :string, enum: ["cron", "once"]},
        cron_expression: %Schema{
          type: :string,
          nullable: true,
          description: "Required for cron tasks"
        },
        scheduled_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Required for one-time tasks"
        },
        enabled: %Schema{type: :boolean, default: true},
        muted: %Schema{
          type: :boolean,
          default: false,
          description: "Mute notifications for this task"
        },
        timeout_ms: %Schema{type: :integer, default: 30000},
        retry_attempts: %Schema{type: :integer, default: 3},
        callback_url: %Schema{
          type: :string,
          format: :uri,
          nullable: true,
          description: "URL to receive POST with execution results"
        },
        expected_status_codes: %Schema{
          type: :string,
          nullable: true,
          description:
            "Comma-separated HTTP status codes that count as success (e.g. \"200,201\"). Empty means any 2xx."
        },
        expected_body_pattern: %Schema{
          type: :string,
          nullable: true,
          description:
            "Response body must contain this text to count as success. Empty means any body."
        }
      },
      example: %{
        name: "Daily cleanup",
        url: "https://example.com/api/cleanup",
        method: "POST",
        schedule_type: "cron",
        cron_expression: "0 0 * * *"
      }
    })
  end

  defmodule TaskResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TaskResponse",
      description: "Response containing a task",
      type: :object,
      properties: %{
        data: Task
      }
    })
  end

  defmodule TasksResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TasksResponse",
      description: "Response containing a paginated list of tasks",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Task},
        has_more: %Schema{type: :boolean, description: "Whether more results exist beyond this page"},
        limit: %Schema{type: :integer, description: "Maximum results per page"},
        offset: %Schema{type: :integer, description: "Number of results skipped"}
      }
    })
  end

  defmodule Execution do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Execution",
      description: "A task execution record",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: ["pending", "running", "success", "failed", "timeout"]
        },
        scheduled_for: %Schema{type: :string, format: :"date-time"},
        started_at: %Schema{type: :string, format: :"date-time", nullable: true},
        finished_at: %Schema{type: :string, format: :"date-time", nullable: true},
        status_code: %Schema{type: :integer, nullable: true},
        duration_ms: %Schema{type: :integer, nullable: true},
        error_message: %Schema{type: :string, nullable: true},
        attempt: %Schema{type: :integer}
      }
    })
  end

  defmodule ExecutionsResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ExecutionsResponse",
      description: "Response containing execution history",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Execution}
      }
    })
  end

  defmodule TriggerResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "TriggerResponse",
      description: "Response from triggering a task",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            execution_id: %Schema{type: :string, format: :uuid},
            status: %Schema{type: :string},
            scheduled_for: %Schema{type: :string, format: :"date-time"}
          }
        },
        message: %Schema{type: :string}
      }
    })
  end

  defmodule SyncRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SyncRequest",
      description:
        "Request body for declarative sync of tasks, monitors, and/or endpoints",
      type: :object,
      properties: %{
        tasks: %Schema{
          type: :array,
          items: TaskRequest,
          description: "List of recurring (cron) tasks to sync"
        },
        monitors: %Schema{
          type: :array,
          items: PrikkeWeb.Schemas.MonitorRequest,
          description: "List of monitors to sync"
        },
        endpoints: %Schema{
          type: :array,
          items: PrikkeWeb.Schemas.EndpointRequest,
          description: "List of inbound endpoints to sync"
        },
        delete_removed: %Schema{
          type: :boolean,
          default: false,
          description: "Delete resources not in the list"
        }
      },
      example: %{
        tasks: [
          %{
            name: "Task A",
            url: "https://example.com/a",
            schedule_type: "cron",
            cron_expression: "0 * * * *"
          }
        ],
        monitors: [
          %{
            name: "Heartbeat",
            schedule_type: "interval",
            interval_seconds: 300
          }
        ],
        endpoints: [
          %{
            name: "Stripe webhooks",
            forward_url: "https://myapp.com/webhooks/stripe"
          }
        ],
        delete_removed: false
      }
    })
  end

  defmodule SyncResourceResult do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SyncResourceResult",
      description: "Sync result for a resource type",
      type: :object,
      properties: %{
        created: %Schema{type: :array, items: %Schema{type: :string}},
        updated: %Schema{type: :array, items: %Schema{type: :string}},
        deleted: %Schema{type: :array, items: %Schema{type: :string}},
        created_count: %Schema{type: :integer},
        updated_count: %Schema{type: :integer},
        deleted_count: %Schema{type: :integer}
      }
    })
  end

  defmodule SyncResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SyncResponse",
      description: "Response from sync operation",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            tasks: SyncResourceResult,
            monitors: SyncResourceResult,
            endpoints: SyncResourceResult,
            created: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Deprecated: use tasks.created"
            },
            updated: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Deprecated: use tasks.updated"
            },
            deleted: %Schema{
              type: :array,
              items: %Schema{type: :string},
              description: "Deprecated: use tasks.deleted"
            },
            created_count: %Schema{
              type: :integer,
              description: "Deprecated: use tasks.created_count"
            },
            updated_count: %Schema{
              type: :integer,
              description: "Deprecated: use tasks.updated_count"
            },
            deleted_count: %Schema{
              type: :integer,
              description: "Deprecated: use tasks.deleted_count"
            }
          }
        },
        message: %Schema{type: :string}
      }
    })
  end

  defmodule Monitor do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Monitor",
      description: "A heartbeat monitor (dead man's switch)",
      type: :object,
      required: [:id, :name, :schedule_type],
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Monitor ID"},
        name: %Schema{type: :string, description: "Monitor name"},
        ping_token: %Schema{type: :string, description: "Unique ping token"},
        ping_url: %Schema{type: :string, format: :uri, description: "Full ping URL"},
        schedule_type: %Schema{
          type: :string,
          enum: ["cron", "interval"],
          description: "Schedule type"
        },
        cron_expression: %Schema{
          type: :string,
          nullable: true,
          description: "Cron expression (for cron monitors)"
        },
        interval_seconds: %Schema{
          type: :integer,
          nullable: true,
          description: "Expected interval in seconds (for interval monitors)"
        },
        grace_period_seconds: %Schema{
          type: :integer,
          default: 300,
          description: "Grace period before alerting (seconds)"
        },
        status: %Schema{
          type: :string,
          enum: ["new", "up", "down", "paused"],
          description: "Current monitor status"
        },
        enabled: %Schema{
          type: :boolean,
          default: true,
          description: "Whether the monitor is active"
        },
        muted: %Schema{
          type: :boolean,
          default: false,
          description: "Whether notifications are muted for this monitor"
        },
        last_ping_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the last ping was received"
        },
        next_expected_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the next ping is expected"
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Last update timestamp"
        }
      },
      example: %{
        id: "019c0123-4567-7890-abcd-ef1234567890",
        name: "Nightly Backup",
        ping_token: "pm_abc123def456",
        ping_url: "https://runlater.eu/ping/pm_abc123def456",
        schedule_type: "interval",
        interval_seconds: 86400,
        grace_period_seconds: 1800,
        status: "up",
        enabled: true,
        last_ping_at: "2026-02-06T02:05:00Z",
        next_expected_at: "2026-02-07T02:05:00Z",
        inserted_at: "2026-01-29T10:00:00Z",
        updated_at: "2026-02-06T02:05:00Z"
      }
    })
  end

  defmodule MonitorRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MonitorRequest",
      description: "Request body for creating or updating a monitor",
      type: :object,
      required: [:name, :schedule_type],
      properties: %{
        name: %Schema{type: :string, description: "Monitor name"},
        schedule_type: %Schema{type: :string, enum: ["cron", "interval"]},
        cron_expression: %Schema{
          type: :string,
          nullable: true,
          description: "Required for cron monitors"
        },
        interval_seconds: %Schema{
          type: :integer,
          nullable: true,
          description: "Required for interval monitors (60-604800)"
        },
        grace_period_seconds: %Schema{
          type: :integer,
          default: 300,
          description: "Grace period in seconds (0-3600)"
        },
        enabled: %Schema{type: :boolean, default: true},
        muted: %Schema{
          type: :boolean,
          default: false,
          description: "Mute notifications for this monitor"
        }
      },
      example: %{
        name: "Nightly Backup",
        schedule_type: "interval",
        interval_seconds: 86400,
        grace_period_seconds: 1800
      }
    })
  end

  defmodule MonitorResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MonitorResponse",
      description: "Response containing a monitor",
      type: :object,
      properties: %{
        data: Monitor
      }
    })
  end

  defmodule MonitorsResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MonitorsResponse",
      description: "Response containing a list of monitors",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: Monitor}
      }
    })
  end

  defmodule MonitorPing do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MonitorPing",
      description: "A ping received by a monitor",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Ping ID"},
        received_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the ping was received"
        }
      }
    })
  end

  defmodule MonitorPingsResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MonitorPingsResponse",
      description: "Response containing a list of monitor pings",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: MonitorPing}
      }
    })
  end

  defmodule PingResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PingResponse",
      description: "Response from a successful ping",
      type: :object,
      properties: %{
        status: %Schema{type: :string, description: "Always \"ok\""},
        monitor: %Schema{type: :string, description: "Monitor name"}
      },
      example: %{
        status: "ok",
        monitor: "Nightly Backup"
      }
    })
  end

  defmodule EndpointSchema do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Endpoint",
      description: "An inbound webhook endpoint",
      type: :object,
      required: [:id, :name, :slug, :forward_url],
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Endpoint ID"},
        name: %Schema{type: :string, description: "Endpoint name"},
        slug: %Schema{type: :string, description: "Unique slug for inbound URL"},
        inbound_url: %Schema{type: :string, format: :uri, description: "Full inbound URL"},
        forward_url: %Schema{type: :string, format: :uri, description: "URL to forward events to"},
        enabled: %Schema{type: :boolean, default: true, description: "Whether the endpoint is active"},
        inserted_at: %Schema{type: :string, format: :"date-time", description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :"date-time", description: "Last update timestamp"}
      },
      example: %{
        id: "019c0123-4567-7890-abcd-ef1234567890",
        name: "Stripe webhooks",
        slug: "ep_abc123def456ghi789jkl012mno345",
        inbound_url: "https://runlater.eu/in/ep_abc123def456ghi789jkl012mno345",
        forward_url: "https://myapp.com/webhooks/stripe",
        enabled: true,
        inserted_at: "2026-01-29T10:00:00Z",
        updated_at: "2026-01-29T10:00:00Z"
      }
    })
  end

  defmodule EndpointRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EndpointRequest",
      description: "Request body for creating or updating an endpoint",
      type: :object,
      required: [:name, :forward_url],
      properties: %{
        name: %Schema{type: :string, description: "Endpoint name"},
        forward_url: %Schema{type: :string, format: :uri, description: "URL to forward events to"},
        enabled: %Schema{type: :boolean, default: true}
      },
      example: %{
        name: "Stripe webhooks",
        forward_url: "https://myapp.com/webhooks/stripe"
      }
    })
  end

  defmodule EndpointResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EndpointResponse",
      description: "Response containing an endpoint",
      type: :object,
      properties: %{
        data: EndpointSchema
      }
    })
  end

  defmodule EndpointsResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EndpointsResponse",
      description: "Response containing a list of endpoints",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: EndpointSchema}
      }
    })
  end

  defmodule InboundEvent do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InboundEvent",
      description: "An inbound webhook event received by an endpoint",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Event ID"},
        method: %Schema{type: :string, description: "HTTP method of the incoming request"},
        source_ip: %Schema{type: :string, description: "IP address of the sender"},
        received_at: %Schema{type: :string, format: :"date-time", description: "When the event was received"},
        execution_id: %Schema{type: :string, format: :uuid, nullable: true, description: "Forwarding execution ID"},
        execution_status: %Schema{type: :string, nullable: true, description: "Forwarding execution status"}
      }
    })
  end

  defmodule InboundEventsResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InboundEventsResponse",
      description: "Response containing a list of inbound events",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: InboundEvent}
      }
    })
  end

  defmodule ReplayResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ReplayResponse",
      description: "Response from replaying an inbound event",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            execution_id: %Schema{type: :string, format: :uuid},
            status: %Schema{type: :string},
            scheduled_for: %Schema{type: :string, format: :"date-time"}
          }
        },
        message: %Schema{type: :string}
      }
    })
  end

  defmodule ErrorResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Error response",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string},
            message: %Schema{type: :string},
            details: %Schema{type: :object, additionalProperties: true}
          }
        }
      }
    })
  end
end
