require 'sinatra'
require 'sinatra/reloader' if development?
require 'sinatra/content_for'
helpers Sinatra::ContentFor

require 'securerandom'
require 'json'
require 'fileutils'
require 'time' # Assurez-vous que 'time' est inclus

# --- Modèles ---

class User
  @@instances = []
  attr_reader :id, :name

  def initialize(name)
    @id = self.class.generate_uniq_id
    @name = name
    @@instances << self
  end

  def self.generate_uniq_id
    SecureRandom.uuid
  end

  def self.find_by_id(id)
    all.find { |user| user.id == id }
  end

  def self.find_by_name(name)
    all.find_all { |user| user.name == name }
  end

  def self.all
    @@instances
  end
end

class Account
  @@instances = []
  attr_reader :id, :owner, :operations
  attr_accessor :state, :balance

  def initialize(user)
    @id = self.class.generate_uniq_id
    @owner = user
    @operations = []
    @state = 1
    @balance = 0
    @@instances << self
  end

  def active?
    @state == 1
  end

  def inactive?
    @state == 0
  end

  def active!
    @state = 1
  end

  def inactive!
    @state = 0
  end

  def can_withdraw?(amount)
    balance >= amount && active?
  end

  def self.generate_uniq_id
    SecureRandom.uuid
  end

  def self.find_by_id(id)
    all.find { |account| account.id == id }
  end

  def self.find_by_user(user)
    all.find_all { |account| account.owner == user }
  end

  def self.all
    @@instances
  end
end

class Operation
  attr_reader :id, :type, :amount, :account, :created_at

  def initialize(type, amount, account)
    raise StandardError, "Account is inactive" if account.inactive?
    raise StandardError, "Insufficient Funds" if type == "withdraw" && !account.can_withdraw?(amount)

    @id = self.class.generate_uniq_id
    @type = type
    @amount = amount
    @account = account
    @created_at = Time.now # La date et l'heure sont enregistrées à la création
  end

  def execute
    if @type == "deposit"
      @account.balance += @amount
    elsif @type == "withdraw"
      @account.balance -= @amount
    end
    @account.operations << self
  end

  def self.generate_uniq_id
    SecureRandom.uuid
  end
end

# --- Données en mémoire ---
$users = {}
$accounts = {}

# --- Persistance JSON ---
DB_FILE = "db/data.json"

def save_data
  data = {
    users: User.all.map { |u| { id: u.id, name: u.name } },
    accounts: Account.all.map do |a|
      {
        id: a.id,
        owner_id: a.owner.id,
        state: a.state,
        balance: a.balance
      }
    end
  }
  FileUtils.mkdir_p(File.dirname(DB_FILE))
  File.write(DB_FILE, JSON.pretty_generate(data))
end

def load_data
  return unless File.exist?(DB_FILE)

  raw = File.read(DB_FILE)
  data = JSON.parse(raw, symbolize_names: true)

  data[:users].each do |u|
    user = User.new(u[:name])
    user.instance_variable_set(:@id, u[:id])
    $users[user.id] = user
  end

  data[:accounts].each do |a|
    owner = $users[a[:owner_id]]
    next unless owner
    account = Account.new(owner)
    account.instance_variable_set(:@id, a[:id])
    account.state = a[:state]
    account.balance = a[:balance]
    $accounts[account.id] = account
  end
end

# --- Fonctions utilitaires ---
def find_user(user_id)
  $users[user_id]
end

def find_account(account_id)
  $accounts[account_id]
end

# --- Routes ---

get '/' do
  @current_time = Time.now.strftime("%d/%m/%Y %H:%M:%S")
  erb :index
end

# Utilisateurs
get '/users/new' do
  erb :new_user
end

post '/users/create' do
  name = params[:name]
  if name && !name.empty?
    user = User.new(name)
    $users[user.id] = user
    save_data
    redirect '/users'
  else
    @error = "Le nom est requis."
    erb :new_user
  end
end

get '/users' do
  @users = User.all
  erb :list_users
end

get '/users/:id' do
  @user = find_user(params[:id])
  if @user
    erb :show_user
  else
    @error = "Utilisateur non trouvé."
    erb :error
  end
end

# Comptes
get '/accounts/new' do
  @users = User.all
  erb :new_account
end

post '/accounts/create' do
  user_id = params[:user_id]
  user = find_user(user_id)
  if user
    account = Account.new(user)
    $accounts[account.id] = account
    save_data
    redirect '/accounts'
  else
    @error = "Utilisateur non trouvé."
    erb :error
  end
end

get '/accounts' do
  @accounts = Account.all
  erb :list_accounts
end

get '/accounts/:id' do
  @account = find_account(params[:id])
  if @account
    erb :show_account
  else
    @error = "Compte non trouvé."
    erb :error
  end
end

post '/accounts/:id/deactivate' do
  account = find_account(params[:id])
  if account
    account.inactive!
    save_data
    redirect "/accounts/#{account.id}"
  else
    @error = "Compte non trouvé."
    erb :error
  end
end

post '/accounts/:id/activate' do
  account = find_account(params[:id])
  if account
    account.active!
    save_data
    redirect "/accounts/#{account.id}"
  else
    @error = "Compte non trouvé."
    erb :error
  end
end

# Dépôt et retrait
get '/accounts/:account_id/deposit' do
  @account_id = params[:account_id]
  erb :deposit
end

post '/accounts/:account_id/deposit' do
  account = find_account(params[:account_id])
  amount = params[:amount].to_f
  if account && account.active? && amount > 0
    operation = Operation.new("deposit", amount, account)
    operation.execute
    save_data
    redirect "/accounts/#{account.id}"
  else
    @error = "Erreur de dépôt."
    erb :deposit
  end
end

get '/accounts/:account_id/withdraw' do
  @account_id = params[:account_id]
  erb :withdraw
end

post '/accounts/:account_id/withdraw' do
  account = find_account(params[:account_id])
  amount = params[:amount].to_f
  if account && account.active? && amount > 0 && account.can_withdraw?(amount)
    begin
      operation = Operation.new("withdraw", amount, account)
      operation.execute
      save_data
      redirect "/accounts/#{account.id}"
    rescue StandardError => e
      @error = e.message
      erb :withdraw
    end
  else
    @error = "Erreur de retrait."
    erb :withdraw
  end
end

# Recherche
get '/search/accounts/by_user' do
  @users = User.all
  erb :search_accounts_by_user
end

post '/search/accounts/by_user' do
  user_id = params[:user_id]
  user = find_user(user_id)
  if user
    @accounts = Account.find_by_user(user)
    erb :list_accounts
  else
    @error = "Utilisateur non trouvé."
    erb :error
  end
end

get '/search/accounts/by_id' do
  erb :search_account_by_id
end

post '/search/accounts/by_id' do
  account_id = params[:account_id]
  account = find_account(account_id)
  if account
    @account = account
    erb :show_account
  else
    @error = "Compte non trouvé."
    erb :error
  end
end

# Erreurs
not_found do
  status 404
  "Page introuvable."
end

# Chargement des données au démarrage
load_data