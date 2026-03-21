# Afghan Student Organization - Project guide

Welcome to the [**Afghan Student Organization**](https://www.instagram.com/afghanskstudenterunion/).

This guide is designed for anyone taking over the project.

### How to Locally Run This Project 

Open the [terminal](https://www.google.com/search?q=what+is+a+terminal+computer) and run:
```bash
open index.html
```

### Folder Structure

Here is how your files are organized:

- The **[Root Directory](https://en.wikipedia.org/wiki/Root_directory) `/`** holds all files.
  - All [`.html` (HTML)](https://developer.mozilla.org/en-US/docs/Learn/HTML/Introduction_to_HTML) files: These are your pages.
    - `index.html` = homepage
    - `om.html` = about page
    - `ressourcer.html` = resources page
    - `kontakt.html` = contact page
  - `style.css`: Handles [design elements (CSS)](https://developer.mozilla.org/en-US/docs/Learn/CSS/First_steps/What_is_CSS). This controls all colors, fonts, and spacing.
  - `script.js`: Controls the "Movement" of the site using [JavaScript](https://developer.mozilla.org/en-US/docs/Learn/JavaScript/First_steps/What_is_JavaScript). Specifically:
    - **Header Transitions**: Makes the navigation bar thinner and transparent when you scroll.
    - **Homepage Slideshow**: Automatically rotates the high-res Afghan/Copenhagen  images.
    - **Fade-in Animations**: Triggers the smooth "reveal" effect as you scroll down the pages.
    - **Smooth Navigation**: Ensures that clicking links glides smoothly to sections.

- The **`images`** folder holds all images.
  - `slides`: Contains all high-resolution images used in the homepage slideshow.
  - `board`: Contains photos of the board members. 
    - Currently the  starting lineup of the 2016 Golden State Warriors.

### How to Update the Site

#### 1. Updating Text
Open any `.html` file. Look for the text between tags like `<p>` or `<h3>`. You can change the Danish text there, and it will update on the site immediately.

#### 2. Adding News (Nyheder)
To add a new story, open `nyheder.html`. Copy an existing `<div class="journal-entry">` block and paste it at the top of the list. Update the date, heading, and text.

#### 3. Swapping Slideshow Images
1. Save your new image in `images/slides/`.
2. Open `index.html`.
3. Find the `<div class="slide">` section and update the `url('images/slides/your-image.jpg')`.

### Design Principles
- **Aesthetics**: Minimalist, open, and elegant.
- **Fonts**: We use *Cormorant Garamond* and *Inter*. 
- **Accents**: Our "ASU Gold" is `hsl(45, 95%, 55%)`. Use it sparingly.