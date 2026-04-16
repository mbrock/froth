defmodule Froth.Video.WorkerFleetTest do
  use ExUnit.Case, async: false

  alias Froth.Video.{ComputeWorker, WorkerFleet}

  test "local_offer/1 exposes the configured browser profile and ignores request overrides" do
    previous_browser_config = Application.get_env(:froth, Froth.Browser, [])
    previous_video_config = Application.get_env(:froth, Froth.Video, [])

    Application.put_env(
      :froth,
      Froth.Browser,
      Keyword.put(previous_browser_config, :profile, :headless_bulk)
    )

    Application.put_env(
      :froth,
      Froth.Video,
      Keyword.put(previous_video_config, :browser_profile, :headless_bulk)
    )

    on_exit(fn ->
      Application.put_env(:froth, Froth.Browser, previous_browser_config)
      Application.put_env(:froth, Froth.Video, previous_video_config)
    end)

    offer = ComputeWorker.local_offer(compute_worker_slots: 3, browser_profile: :headful_debug)

    assert offer.node == node()
    assert offer.slots == 3
    assert offer.browser_profile == "headless_bulk"
    assert offer.headless == true
    assert offer.headful == false
    assert offer.visible == false
    assert offer.gpu == false
  end

  test "worker_offers/1 falls back to the configured browser profile" do
    previous_browser_config = Application.get_env(:froth, Froth.Browser, [])
    previous_video_config = Application.get_env(:froth, Froth.Video, [])

    Application.put_env(:froth, Froth.Browser, profile: :headful_debug)

    Application.put_env(
      :froth,
      Froth.Video,
      Keyword.delete(previous_video_config, :browser_profile)
    )

    on_exit(fn ->
      Application.put_env(:froth, Froth.Browser, previous_browser_config)
      Application.put_env(:froth, Froth.Video, previous_video_config)
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

  test "worker_offers/1 filters offers to nodes that support a requested headful profile" do
    offers = [
      %{
        node: :"froth@mikaels-mac-mini-2",
        hostname: "mikaels-mac-mini-2",
        slots: 1,
        browser_profile: "headful_debug",
        visible: true,
        headful: true,
        headless: false,
        gpu: true
      },
      %{
        node: :froth@igloo,
        hostname: "igloo",
        slots: 2,
        browser_profile: "headless_bulk",
        visible: false,
        headful: false,
        headless: true,
        gpu: false
      }
    ]

    [offer] = WorkerFleet.worker_offers(worker_offers: offers, browser_profile: :headful_debug)

    assert offer.node == :"froth@mikaels-mac-mini-2"
    assert offer.headful == true
  end

  test "worker_offers/1 filters offers using all requested capability flags" do
    mac = :"froth@mikaels-mac-mini-2"
    igloo = :froth@igloo
    swa = :froth@swa

    offers = [
      %{
        node: mac,
        hostname: "mikaels-mac-mini-2",
        slots: 1,
        browser_profile: "headful_debug",
        visible: true,
        headful: true,
        headless: false,
        gpu: true
      },
      %{
        node: igloo,
        hostname: "igloo",
        slots: 2,
        browser_profile: "headless_gpu",
        visible: false,
        headful: false,
        headless: true,
        gpu: true
      },
      %{
        node: swa,
        hostname: "swa",
        slots: 2,
        browser_profile: "headless_bulk",
        visible: false,
        headful: false,
        headless: true,
        gpu: false
      }
    ]

    [offer] = WorkerFleet.worker_offers(worker_offers: offers, browser_profile: :headless_gpu)

    assert offer.node == igloo
    assert offer.headless == true
    assert offer.gpu == true
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

  test "run/3 uses only workers that satisfy the requested capability and waits for them" do
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
               browser_profile: :headful_debug,
               start_worker_fun: start_worker_fun
             )

    assert_received {:worker_started, %{node: :"froth@mikaels-mac-mini-2"}, "job-123",
                     "render-123", :headful_debug}

    refute_received {:worker_started, %{node: :froth@igloo}, "job-123", "render-123",
                     :headful_debug}
  end

  test "run/3 returns an error when no offered nodes satisfy the requested capability" do
    offers = [
      %{
        node: :"froth@mikaels-mac-mini-2",
        hostname: "mikaels-mac-mini-2",
        slots: 1,
        browser_profile: "headful_debug",
        visible: true,
        headful: true,
        headless: false,
        gpu: true
      },
      %{
        node: :froth@igloo,
        hostname: "igloo",
        slots: 2,
        browser_profile: "headless_bulk",
        visible: false,
        headful: false,
        headless: true,
        gpu: false
      }
    ]

    assert {:error, :no_compute_workers_available} =
             WorkerFleet.run("job-123", "render-123",
               worker_offers: offers,
               browser_profile: :headless_gpu
             )
  end
end
