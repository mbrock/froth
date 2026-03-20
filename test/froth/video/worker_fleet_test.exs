defmodule Froth.Video.WorkerFleetTest do
  use ExUnit.Case, async: true

  alias Froth.Video.WorkerFleet

  test "worker_offers/1 exposes the local browser profile and slots" do
    [offer] =
      WorkerFleet.worker_offers(
        connected_nodes: [],
        compute_worker_slots: 3,
        browser_profile: :headful_debug
      )

    assert offer.node == node()
    assert offer.slots == 3
    assert offer.browser_profile == "headful_debug"
    assert offer.headful == true
    assert offer.visible == true
    assert offer.gpu == true
  end

  test "worker_offers/1 falls back to the configured browser profile" do
    previous_browser_config = Application.get_env(:froth, Froth.Browser, [])

    Application.put_env(:froth, Froth.Browser, profile: :headful_debug)

    on_exit(fn ->
      Application.put_env(:froth, Froth.Browser, previous_browser_config)
    end)

    [offer] =
      WorkerFleet.worker_offers(
        connected_nodes: [],
        compute_worker_slots: 1
      )

    assert offer.browser_profile == "headful_debug"
    assert offer.headful == true
    assert offer.visible == true
  end

  test "worker_offers/1 skips unreachable remote nodes" do
    [offer] =
      WorkerFleet.worker_offers(
        connected_nodes: [:"froth@definitely-not-a-node"],
        compute_worker_slots: 2
      )

    assert offer.node == node()
    assert offer.slots == 2
  end

  test "build_worker_specs/2 spreads work across offered nodes in rounds" do
    mac = :"froth@mikaels-mac-mini-2"
    igloo = :froth@igloo
    swa = :froth@swa

    offers = [
      %{
        node: mac,
        hostname: "mikaels-mac-mini-2",
        slots: 2,
        browser_profile: "headful_debug",
        visible: true,
        headful: true,
        gpu: true
      },
      %{
        node: igloo,
        hostname: "igloo",
        slots: 2,
        browser_profile: "headless_bulk",
        visible: false,
        headful: false,
        gpu: false
      },
      %{
        node: swa,
        hostname: "swa",
        slots: 1,
        browser_profile: "headless_bulk",
        visible: false,
        headful: false,
        gpu: false
      }
    ]

    specs = WorkerFleet.build_worker_specs(offers, 4)

    assert Enum.map(specs, & &1.node) == [mac, igloo, swa, mac]
    assert Enum.map(specs, & &1.worker_index) == [1, 2, 3, 4]
  end

  test "run/3 uses the planned fleet and waits for all workers" do
    test_pid = self()

    offers = [
      %{
        node: :"froth@mikaels-mac-mini-2",
        hostname: "mikaels-mac-mini-2",
        slots: 1,
        browser_profile: "headful_debug",
        visible: true,
        headful: true,
        gpu: true
      },
      %{
        node: :froth@igloo,
        hostname: "igloo",
        slots: 2,
        browser_profile: "headless_bulk",
        visible: false,
        headful: false,
        gpu: false
      }
    ]

    start_worker_fun = fn spec, job_id, render_id, opts ->
      Task.async(fn ->
        send(test_pid, {:worker_started, spec, job_id, render_id, opts[:browser_profile]})
        :ok
      end)
    end

    assert :ok =
             WorkerFleet.run("job-123", "render-123",
               worker_offers: offers,
               compute_workers: 3,
               browser_profile: :headless_gpu,
               start_worker_fun: start_worker_fun
             )

    assert_received {:worker_started, %{node: :"froth@mikaels-mac-mini-2"}, "job-123",
                     "render-123", :headless_gpu}

    assert_received {:worker_started, %{node: :froth@igloo}, "job-123", "render-123",
                     :headless_gpu}

    assert_received {:worker_started, %{node: :froth@igloo, worker_index: 3}, "job-123",
                     "render-123", :headless_gpu}
  end
end
