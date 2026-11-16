Rails.application.routes.draw do
  root 'health#show'
  get 'health' => 'health#show'
end
