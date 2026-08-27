defmodule Auth0.Common.Management.TokenManager do
  @moduledoc false
  defmodule Store do
    @moduledoc false
    @registry :tokens_registry
    @type key :: String.t()
    @type token :: String.t()
    @type expiration :: integer
    @spec init() :: :ok
    def init() do
      case :ets.whereis(@registry) do
        :undefined ->
          create_registry()

        _tid ->
          :ok
      end
    end

    # The table is :public because it is created lazily by whichever caller
    # first misses the cache, and every other caller process must still be able
    # to write to it.
    defp create_registry() do
      _ = :ets.new(@registry, [:set, :public, :named_table])
      :ok
    rescue
      error in ArgumentError ->
        # Another process created the table between the whereis/1 check above
        # and the :ets.new/2 call. That is the outcome we wanted anyway.
        case :ets.whereis(@registry) do
          :undefined -> reraise(error, __STACKTRACE__)
          _tid -> :ok
        end
    end

    @spec get(key) :: {token, expiration} | nil
    def get(key) do
      case with_retry(fn -> :ets.lookup(@registry, key) end) do
        [] -> nil
        [{_key, value}] -> value
      end
    end

    @spec put(key, {token, expiration}) :: :ok
    def put(key, value) do
      _ = with_retry(fn -> :ets.insert(@registry, {key, value}) end)
      :ok
    end

    defp with_retry(func) do
      try do
        func.()
      rescue
        _ ->
          _ = init()
          func.()
      end
    end
  end

  alias Auth0.Config
  alias Auth0.Authentication
  alias Auth0.Entity.Token
  alias Auth0.Authentication.Token.ClientCredentials

  @type config :: Config.t()

  @spec get_token(config) :: String.t() | nil
  def get_token(%Config{token_cache_disabled: true} = config) do
    case config |> request_token() do
      %Token{access_token: access_token} -> access_token
      _ -> nil
    end
  end

  def get_token(%Config{clear_token_cache: clear_token_cache} = config) do
    client_id = config |> Config.get_client_id()

    _ = if clear_token_cache, do: client_id |> Store.put(nil)

    token =
      case client_id |> Store.get() do
        {token, expiration_time_second} ->
          if expired(system_time_second(), expiration_time_second) do
            nil
          else
            token
          end

        _ ->
          nil
      end

    if token |> is_nil do
      case config |> request_token() do
        %Token{access_token: access_token, expires_in: expires_in} ->
          client_id |> Store.put({access_token, system_time_second() + expires_in})
          access_token

        _ ->
          nil
      end
    else
      token
    end
  end

  defp system_time_second(), do: System.system_time(:second)

  defp expired(system_time_second, expiration_time_second) do
    system_time_second - 5 > expiration_time_second
  end

  defp request_token(config) do
    %ClientCredentials.Params{
      audience: config |> get_audience(),
      client_id: config |> Config.get_client_id(),
      client_secret: config |> Config.get_client_secret()
    }
    |> Authentication.token_by_client_credentials(config)
    |> case do
      {:ok, %Token{access_token: access_token} = token}
      when access_token |> is_binary ->
        token

      _ ->
        nil
    end
  end

  defp get_audience(%Config{} = config), do: "https://#{Config.get_domain(config)}/api/v2/"
end
