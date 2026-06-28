#!/usr/bin/env ruby
# One-shot bulk importer. Run with: bundle exec ruby scripts/import_recipes.rb
# Flow: POST /api/recipes (name only) -> PATCH /api/recipes/{slug} (full details).

require "bundler/setup"
require "dotenv/load"
require "net/http"
require "json"
require "uri"

BASE_URL = (ENV["MEALIE_URL"] || "http://mealie:9000").chomp("/")
TOKEN    = ENV["MEALIE_API_TOKEN"]

abort "MEALIE_API_TOKEN not set" unless TOKEN
abort "MEALIE_URL not set"       unless ENV["MEALIE_URL"]

def ingredient(text)
  { "quantity" => 0, "unit" => nil, "food" => nil, "note" => text,
    "display" => text, "title" => nil, "originalText" => text }
end

def step(text)
  { "title" => "", "summary" => "", "text" => text, "ingredientReferences" => [] }
end

RECIPES = [
  {
    name: "Jambalaya",
    description: "Classic Louisiana jambalaya with chicken, andouille, and rice. One pot, weeknight-friendly.",
    recipeYield: "4 servings",
    prepTime: "PT15M",
    cookTime: "PT55M",
    ingredients: [
      "1 onion, chopped",
      "2 ribs celery, chopped",
      "1 green bell pepper, chopped",
      "2 tsp minced garlic",
      "3/4 lb boneless skinless chicken thighs",
      "1/2 lb andouille sausage, sliced",
      "2 oz tomato paste (half a small can)",
      "1 tsp paprika",
      "1/4 tsp cayenne",
      "1/2 tsp dried oregano",
      "2 bay leaves",
      "Cajun seasoning, to coat chicken",
      "2 tsp Crystal hot sauce",
      "1 cup rice",
      "1 carton (32 oz) chicken stock",
      "1/3 cup fresh parsley, chopped"
    ],
    steps: [
      "Season chicken thighs generously with Cajun seasoning and set aside.",
      "In a heavy pot over medium heat, cook onion, bell pepper, and celery for about 20 minutes until softened and starting to caramelize.",
      "Add garlic and cook 2 more minutes.",
      "Add tomato paste, paprika, cayenne, and oregano. Cook 3 minutes, stirring.",
      "Add sliced andouille, hot sauce, and bay leaves. Cook 3–5 minutes.",
      "Add whole chicken thighs and cook until outside is white, 6–8 minutes.",
      "Add chicken stock and rice. Bring to a boil, then reduce to a medium simmer and cover.",
      "Stir every 10–15 minutes until liquid is absorbed — about 30–40 min for white rice, 45–60 min for brown. Watch carefully near the end and stir constantly to prevent burning.",
      "Remove bay leaves. Shred or chop chicken if desired. Finish with fresh parsley."
    ]
  },
  {
    name: "Chili",
    description: "Hearty ground beef chili with kidney and black beans, Ro-Tel, and a rich spice blend. Great with all the toppings.",
    recipeYield: "6 servings",
    prepTime: "PT15M",
    cookTime: "PT60M",
    ingredients: [
      "2 lbs ground beef",
      "Olive oil",
      "1/2 onion, diced",
      "4–6 cloves garlic, minced",
      "3 tbsp chili powder",
      "1 tbsp cumin",
      "1 tbsp dried oregano",
      "1/2 tbsp garlic powder",
      "1/2 tbsp onion powder",
      "2 bay leaves",
      "2 tsp MSG",
      "Salt and pepper to taste",
      "1–3 tbsp cornstarch or potato starch",
      "2 tbsp tomato paste",
      "2 cups chicken stock",
      "2 cans kidney beans, drained",
      "2 cans black beans, drained",
      "1 can (28 oz) Ro-Tel diced tomatoes and chilies",
      "Shredded cheese, diced avocado, sliced jalapeños, sour cream, hot sauce, cilantro (for topping)"
    ],
    steps: [
      "Heat olive oil in a large pot over medium heat. Add onion with 1/2 tbsp salt and cook until translucent or caramelized. Remove from pot.",
      "Brown beef in the pot in batches if needed so it doesn't steam — let it char slightly on each side. Remove excess fat, leaving 1–2 tbsp in the pot.",
      "Combine all beef, the cooked onions, all spices, garlic, and tomato paste in the pot. Stir and cook for 1 minute.",
      "Add drained beans, Ro-Tel (with liquid), and chicken stock. Stir to combine and reduce to a simmer. Cook at least 30 minutes, up to 60, stirring occasionally.",
      "Remove bay leaves. Stir in cornstarch 1 tbsp at a time to reach desired thickness, allowing 1–2 minutes between additions.",
      "Taste and adjust salt and spices. Serve with toppings."
    ]
  },
  {
    name: "Wild Mushroom Risotto",
    description: "Creamy Parmesan risotto with a full pound of mixed wild mushrooms. Vegetarian.",
    recipeYield: "4 servings",
    prepTime: "PT15M",
    cookTime: "PT40M",
    ingredients: [
      "3 cans (14.5 oz each) vegetable broth",
      "3 tbsp butter",
      "3 tbsp olive oil",
      "9 shallots, chopped",
      "1 lb assorted wild mushrooms (oyster, crimini, stemmed shiitake), sliced",
      "1 cup arborio or medium-grain rice",
      "1/2 cup dry Sherry",
      "1/2 cup freshly grated Parmesan cheese (about 2 oz)",
      "3/4 tsp chopped fresh thyme"
    ],
    steps: [
      "Bring vegetable broth to a simmer in a separate saucepan; keep warm.",
      "Melt butter with olive oil in a heavy large saucepan over medium heat. Add shallots and sauté until tender and golden, about 12 minutes.",
      "Add mushrooms and sauté until tender and juices are released, about 8 minutes.",
      "Add rice and stir to coat. Add Sherry and simmer, stirring frequently, until absorbed, about 3 minutes.",
      "Add 3/4 cup hot broth and simmer, stirring frequently, until absorbed. Continue adding broth 3/4 cup at a time, letting each addition absorb before adding more, until rice is just tender and creamy, about 20 minutes total.",
      "Stir in Parmesan and fresh thyme. Season with salt and pepper. Serve immediately."
    ]
  },
  {
    name: "French Toast Casserole",
    description: "America's Test Kitchen overnight French toast casserole with a pecan brown sugar topping. Great for Sunday brunch.",
    recipeYield: "8 servings",
    prepTime: "PT20M",
    cookTime: "PT1H25M",
    ingredients: [
      "1 loaf (16 oz) French or Italian bread, torn into 1-inch pieces",
      "1 tbsp unsalted butter, softened (for pan)",
      "8 large eggs",
      "2 1/2 cups whole milk",
      "1 1/2 cups heavy cream",
      "1 tbsp granulated sugar",
      "2 tsp vanilla extract",
      "1/2 tsp ground cinnamon",
      "1/2 tsp ground nutmeg",
      "8 tbsp (1 stick) unsalted butter, softened (topping)",
      "1 1/2 cups packed light brown sugar (topping)",
      "3 tbsp light corn syrup (topping)",
      "2 cups pecans, coarsely chopped (topping)"
    ],
    steps: [
      "Heat oven to 325°F. Spread bread pieces on a rimmed baking sheet and bake until dried and lightly toasted, about 25 minutes. Let cool 5 minutes.",
      "Coat a 13x9-inch baking dish with 1 tbsp softened butter. Whisk eggs, milk, cream, granulated sugar, vanilla, cinnamon, and nutmeg in a large bowl until combined.",
      "Add dried bread to the custard and toss gently, pressing so bread absorbs the liquid. Let sit 30 minutes, tossing occasionally, until most custard is absorbed. Transfer to prepared baking dish.",
      "For the topping: mix softened butter, brown sugar, corn syrup, and pecans until combined. Spread evenly over the casserole.",
      "To store overnight: cover tightly with plastic wrap and refrigerate up to 24 hours.",
      "To bake: adjust oven rack to middle position and heat oven to 325°F. Remove plastic wrap. Bake until top is golden brown and puffed and custard is set, about 60 minutes. Let rest 10 minutes before serving."
    ]
  }
].freeze

def api(method, path, body = nil)
  uri  = URI("#{BASE_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = 10
  http.read_timeout = 15

  req = case method
        when :post   then Net::HTTP::Post.new(uri)
        when :patch  then Net::HTTP::Patch.new(uri)
        when :delete then Net::HTTP::Delete.new(uri)
        end
  req["Authorization"] = "Bearer #{TOKEN}"
  req["Content-Type"]  = "application/json"
  req.body = JSON.generate(body) if body
  http.request(req)
end

puts "Importing #{RECIPES.length} recipes into #{BASE_URL}...\n\n"

RECIPES.each do |r|
  print "  #{r[:name]}... "

  # Step 1: create skeleton, get slug back
  res = api(:post, "/api/recipes", { name: r[:name] })
  unless res.code.to_i == 201
    puts "CREATE FAILED #{res.code}: #{res.body[0, 150]}"
    next
  end
  slug = JSON.parse(res.body)

  # Step 2: fill in details
  payload = {
    name:                r[:name],
    description:         r[:description],
    recipeYield:         r[:recipeYield],
    prepTime:            r[:prepTime],
    cookTime:            r[:cookTime],
    recipeIngredient:    r[:ingredients].map { |i| ingredient(i) },
    recipeInstructions:  r[:steps].map { |s| step(s) }
  }
  res2 = api(:patch, "/api/recipes/#{slug}", payload)
  if res2.code.to_i == 200
    puts "OK  →  #{BASE_URL}/r/#{slug}"
  else
    puts "PATCH FAILED #{res2.code}: #{res2.body[0, 150]}"
  end
end

puts "\nDone. Open Mealie and verify one recipe before tagging."
