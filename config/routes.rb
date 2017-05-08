Rails.application.routes.draw do
  # For details on the DSL available within this file, see http://guides.rubyonrails.org/routing.html

  root 'app2csv#main'
  get '/step1' => 'app2csv#step1'
  post '/step1' => 'app2csv#step1'

  get '/step2' => 'app2csv#step2'
  post '/step2' => 'app2csv#step2'

  post '/step3' => 'app2csv#step3'

  post 'app2csv/download_step1', as: :download_step1
  post 'app2csv/download_step2', as: :download_step2
  post 'app2csv/download_step3', as: :download_step3


end
